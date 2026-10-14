package brain

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"math"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"slices"
	"strings"
	"sync"
	"syscall"
	"time"
)

// The local model: Ministral 3B, run by the llama.cpp server on this Mac while Jev or Luna is failing, so Moku keeps
// judging and talking through an outage.
//   - The model (2.1 GB) is downloaded on first run into $MOKU_HOME/models and checked against its SHA-256; the
//     server binary comes from MOKU_LLAMA_SERVER (Moku.app sets it to its bundled llama.cpp).
//   - The server starts only when a fallback is needed and stops after 10 minutes without one.
//   - It answers only what was measured: the focus question (p(work) from the first answer token's probabilities),
//     and schema-constrained writing checked by the caller.
var LocalModelInfo = struct {
	ID, File, URL, SHA256 string
	Bytes                 int64
}{
	ID:     "local/Ministral-3-3B-Instruct-2512-Q4_K_M",
	File:   "Ministral-3-3B-Instruct-2512-Q4_K_M.gguf",
	URL:    "https://huggingface.co/mistralai/Ministral-3-3B-Instruct-2512-GGUF/resolve/eb599d408350ea2bb60452cb86be7c7b2fc28227/Ministral-3-3B-Instruct-2512-Q4_K_M.gguf",
	SHA256: "9ed150d4367e68df0ac8e1540f6ddc65b42d0ee26378329d1ecbca60f93fc5f8",
	Bytes:  2_147_023_008,
}

const (
	localIdleStopMs    = 10 * 60_000
	localStartTimeout  = 30 * time.Second
	minFreeBytesAfter  = 2_000_000_000
)

var downloadRetryMs = []int64{60_000, 5 * 60_000, 30 * 60_000}

type LocalHealth struct {
	State    string   `json:"state"` // missing | downloading | ready | running | failed
	Progress *float64 `json:"progress,omitempty"`
}

type LocalJudge struct{ PWork float64 }

type LocalWrite struct {
	OK                  bool
	Output              any
	TokensIn, TokensOut int64
}

type LocalModel interface {
	Warm()
	// JudgeKind answers the focus question only (ok is false for any other question).
	JudgeKind(state any, q EvaluationQuestion, timeoutMs int64) (LocalJudge, bool)
	Write(system, prompt string, schema StringSchema, timeoutMs int64, maxOutputTokens int) LocalWrite
	Prepare()
	Health() LocalHealth
	Close()
}

type LocalOptions struct {
	Home       string
	ServerPath string
	ModelURL   string
	SHA256     string
	Bytes      int64
	IdleStopMs int64
	Logf       func(format string, args ...any)
}

// serverArgs: one slot with a fixed 4,096-token context on the GPU, and no prompt cache in RAM (llama.cpp would keep
// up to 8 GB of old prompts; with --cache-ram 0 it stays at the model plus its context).
func serverArgs(modelPath string, port int) []string {
	return []string{"-m", modelPath, "--host", "127.0.0.1", "--port", fmt.Sprint(port), "-c", "4096", "-ngl", "99", "-np", "1", "--cache-ram", "0", "--no-webui"}
}

func isFocusQuestion(q EvaluationQuestion) bool {
	keys := slices.Sorted(slices.Values(q.Criteria.Keys()))
	return q.Type == "choice" && strings.Join(keys, ",") == "distraction,work"
}

// focusPrompt: the eval's prompt, word for word.
func focusPrompt(q EvaluationQuestion, state any) (system, user string) {
	work, _ := q.Criteria.Get("work")
	distraction, _ := q.Criteria.Get("distraction")
	system = fmt.Sprintf("%s\n\n- work: %s\n- distraction: %s\n\nAnswer with exactly one word: work or distraction.", q.Instructions, work, distraction)
	user = "The screen (JSON):\n" + JSONIndent(state, 1) + "\n\nIs this screen work or a distraction? Answer with one word: work or distraction."
	return
}

var (
	workToken        = regexp.MustCompile(`^w(o(r(k)?)?)?$`)
	distractionToken = regexp.MustCompile(`^d(i(s(t(r(a(c(t(i(o(n)?)?)?)?)?)?)?)?)?)?$`)
)

type topLogprob struct {
	Token   string  `json:"token"`
	Logprob float64 `json:"logprob"`
}

// pWorkFrom: p(work) from the first answer token's top probabilities, or false when too little mass lands on either.
func pWorkFrom(top []topLogprob) (float64, bool) {
	mass := func(re *regexp.Regexp) float64 {
		sum := 0.0
		for _, t := range top {
			token := strings.ToLower(Trim(t.Token))
			if Trim(t.Token) != "" && re.MatchString(token) {
				sum += math.Exp(t.Logprob)
			}
		}
		return sum
	}
	work, distraction := mass(workToken), mass(distractionToken)
	if work+distraction > 0.2 {
		return work / (work + distraction), true
	}
	return 0, false
}

type llamaServer struct {
	cmd   *exec.Cmd
	port  int
	ready chan bool // closed once decided; value readable via readyOK
	ok    bool
}

type localModel struct {
	opts        LocalOptions
	dir         string
	modelPath   string
	mu          sync.Mutex
	server      *llamaServer
	lastUsed    int64
	inUse       int
	failedUntil int64
	downloading *int64 // bytes received
	failures    int
	retry       *time.Timer
	stopIdle    chan struct{}
	logf        func(format string, args ...any)
}

func NewLocalModel(o LocalOptions) LocalModel {
	if o.ModelURL == "" {
		o.ModelURL = LocalModelInfo.URL
	}
	if o.SHA256 == "" {
		o.SHA256 = LocalModelInfo.SHA256
	}
	if o.Bytes == 0 {
		o.Bytes = LocalModelInfo.Bytes
	}
	if o.IdleStopMs == 0 {
		o.IdleStopMs = localIdleStopMs
	}
	logf := o.Logf
	if logf == nil {
		logf = func(format string, args ...any) { log.Printf("local model: "+format, args...) }
	}
	dir := filepath.Join(o.Home, "models")
	l := &localModel{opts: o, dir: dir, modelPath: filepath.Join(dir, LocalModelInfo.File), stopIdle: make(chan struct{}), logf: logf}
	go l.idleLoop()
	return l
}

func (l *localModel) hasModel() bool { _, err := os.Stat(l.modelPath); return err == nil }
func (l *localModel) hasServer() bool {
	if l.opts.ServerPath == "" {
		return false
	}
	_, err := os.Stat(l.opts.ServerPath)
	return err == nil
}

func (l *localModel) idleLoop() {
	interval := time.Duration(min(int64(60_000), max(int64(10), l.opts.IdleStopMs/2))) * time.Millisecond
	t := time.NewTicker(interval)
	defer t.Stop()
	for {
		select {
		case <-l.stopIdle:
			return
		case <-t.C:
			l.mu.Lock()
			if l.server != nil && l.inUse == 0 && nowMs()-l.lastUsed > l.opts.IdleStopMs {
				l.logf("unused for %d minutes; stopping the server", int(math.Round(float64(l.opts.IdleStopMs)/60_000)))
				l.stopLocked()
			}
			l.mu.Unlock()
		}
	}
}

func (l *localModel) stopLocked() {
	if l.server != nil && l.server.cmd.Process != nil {
		l.server.cmd.Process.Signal(syscall.SIGTERM)
	}
	l.server = nil
}

func freePort() (int, error) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return 0, err
	}
	defer ln.Close()
	return ln.Addr().(*net.TCPAddr).Port, nil
}

// start returns the server once it's ready (nil if it can't start).
func (l *localModel) start() *llamaServer {
	l.mu.Lock()
	if s := l.server; s != nil {
		l.mu.Unlock()
		<-s.ready
		if s.ok {
			return s
		}
		return nil
	}
	if !l.hasModel() || !l.hasServer() || nowMs() < l.failedUntil {
		l.mu.Unlock()
		return nil
	}
	port, err := freePort()
	if err != nil {
		l.mu.Unlock()
		return nil
	}
	logFile, _ := os.OpenFile(filepath.Join(l.opts.Home, "llama.log"), os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o600)
	cmd := exec.Command(l.opts.ServerPath, serverArgs(l.modelPath, port)...)
	cmd.Stdout, cmd.Stderr = logFile, logFile
	s := &llamaServer{cmd: cmd, port: port, ready: make(chan bool)}
	if err := cmd.Start(); err != nil {
		l.mu.Unlock()
		return nil
	}
	l.server = s
	l.mu.Unlock()
	exited := make(chan struct{})
	go func() {
		cmd.Wait()
		if logFile != nil {
			logFile.Close()
		}
		close(exited)
		l.mu.Lock()
		if l.server == s {
			l.server = nil
		}
		l.mu.Unlock()
	}()
	started := time.Now()
	client := &http.Client{Timeout: time.Second}
	for time.Since(started) < localStartTimeout {
		select {
		case <-exited:
			goto failed
		default:
		}
		if res, err := client.Get(fmt.Sprintf("http://127.0.0.1:%d/health", port)); err == nil {
			res.Body.Close()
			if res.StatusCode >= 200 && res.StatusCode < 300 {
				l.logf("server ready on port %d in %d ms", port, time.Since(started).Milliseconds())
				s.ok = true
				close(s.ready)
				return s
			}
		}
		time.Sleep(250 * time.Millisecond)
	}
failed:
	l.logf("server did not start; resting 10 minutes")
	l.mu.Lock()
	l.failedUntil = nowMs() + localIdleStopMs
	if cmd.Process != nil {
		cmd.Process.Kill()
	}
	if l.server == s {
		l.server = nil
	}
	l.mu.Unlock()
	close(s.ready)
	return nil
}

// chat posts one chat completion to the server (starting it if needed), within timeoutMs.
func (l *localModel) chat(body OMap, timeoutMs int64) (map[string]any, string) {
	l.mu.Lock()
	l.lastUsed = nowMs()
	l.inUse++
	l.mu.Unlock()
	defer func() {
		l.mu.Lock()
		l.inUse--
		l.lastUsed = nowMs()
		l.mu.Unlock()
	}()
	ctx, cancel := context.WithTimeout(context.Background(), time.Duration(max(1, timeoutMs))*time.Millisecond)
	defer cancel()
	up := make(chan *llamaServer, 1)
	go func() { up <- l.start() }()
	var server *llamaServer
	select {
	case server = <-up:
	case <-ctx.Done():
		return nil, "timeout (loading)"
	}
	if server == nil {
		return nil, "unavailable"
	}
	req, _ := http.NewRequestWithContext(ctx, http.MethodPost, fmt.Sprintf("http://127.0.0.1:%d/v1/chat/completions", server.port), bytes.NewBufferString(JSON(body)))
	req.Header.Set("content-type", "application/json")
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		if ctx.Err() != nil {
			return nil, "timeout"
		}
		return nil, err.Error()
	}
	defer res.Body.Close()
	if res.StatusCode < 200 || res.StatusCode > 299 {
		return nil, fmt.Sprintf("server %d", res.StatusCode)
	}
	var out map[string]any
	if err := json.NewDecoder(res.Body).Decode(&out); err != nil {
		return nil, err.Error()
	}
	return out, ""
}

func (l *localModel) Warm() {
	if l.hasModel() && l.hasServer() {
		l.mu.Lock()
		l.lastUsed = nowMs()
		l.mu.Unlock()
		go l.start()
	}
}

func (l *localModel) JudgeKind(state any, q EvaluationQuestion, timeoutMs int64) (LocalJudge, bool) {
	if !isFocusQuestion(q) {
		return LocalJudge{}, false
	}
	system, user := focusPrompt(q, state)
	res, errText := l.chat(OMap{
		{"messages", []any{OMap{{"role", "system"}, {"content", system}}, OMap{{"role", "user"}, {"content", user}}}},
		{"max_tokens", 1}, {"temperature", 0}, {"logprobs", true}, {"top_logprobs", 20},
	}, timeoutMs)
	if errText != "" {
		return LocalJudge{}, false
	}
	var parsed struct {
		Choices []struct {
			Logprobs struct {
				Content []struct {
					TopLogprobs []topLogprob `json:"top_logprobs"`
				} `json:"content"`
			} `json:"logprobs"`
		} `json:"choices"`
	}
	data, _ := json.Marshal(res)
	if json.Unmarshal(data, &parsed) != nil || len(parsed.Choices) == 0 || len(parsed.Choices[0].Logprobs.Content) == 0 {
		return LocalJudge{}, false
	}
	p, ok := pWorkFrom(parsed.Choices[0].Logprobs.Content[0].TopLogprobs)
	return LocalJudge{PWork: p}, ok
}

func (l *localModel) Write(system, prompt string, schema StringSchema, timeoutMs int64, maxOutputTokens int) LocalWrite {
	if maxOutputTokens == 0 {
		maxOutputTokens = 600
	}
	res, errText := l.chat(OMap{
		{"messages", []any{OMap{{"role", "system"}, {"content", system}}, OMap{{"role", "user"}, {"content", prompt}}}},
		{"max_tokens", maxOutputTokens}, {"temperature", 0.6},
		{"response_format", OMap{{"type", "json_schema"}, {"json_schema", OMap{{"name", "answer"}, {"schema", schema.JSONSchema("https://json-schema.org/draft/2020-12/schema")}}}}},
	}, timeoutMs)
	if errText != "" {
		return LocalWrite{}
	}
	var parsed struct {
		Choices []struct {
			Message struct {
				Content string `json:"content"`
			} `json:"message"`
		} `json:"choices"`
		Usage struct {
			PromptTokens     int64 `json:"prompt_tokens"`
			CompletionTokens int64 `json:"completion_tokens"`
		} `json:"usage"`
	}
	data, _ := json.Marshal(res)
	if json.Unmarshal(data, &parsed) != nil || len(parsed.Choices) == 0 {
		return LocalWrite{}
	}
	var output any
	if json.Unmarshal([]byte(parsed.Choices[0].Message.Content), &output) != nil {
		return LocalWrite{}
	}
	return LocalWrite{OK: true, Output: output, TokensIn: parsed.Usage.PromptTokens, TokensOut: parsed.Usage.CompletionTokens}
}

// Prepare downloads the model if it's missing (first run), in the background, with retries. Only when this Mac has the
// llama.cpp server to run it: without one, 2 GB would sit unused.
func (l *localModel) Prepare() {
	l.mu.Lock()
	busy := l.downloading != nil || l.retry != nil
	l.mu.Unlock()
	if l.hasModel() || busy || !l.hasServer() {
		return
	}
	go l.download()
}

func (l *localModel) download() {
	os.MkdirAll(l.dir, 0o755)
	part := l.modelPath + ".part"
	var have int64
	if info, err := os.Stat(part); err == nil {
		have = info.Size()
	}
	var fs syscall.Statfs_t
	if syscall.Statfs(l.dir, &fs) == nil && int64(fs.Bavail)*int64(fs.Bsize) < l.opts.Bytes-have+minFreeBytesAfter {
		l.logf("not enough free disk space for the local model; not downloading")
		return
	}
	received := have
	l.mu.Lock()
	l.downloading = &received
	l.mu.Unlock()
	if have > 0 {
		l.logf("resuming the download at %d bytes", have)
	} else {
		l.logf("downloading %d bytes", l.opts.Bytes)
	}
	err := func() error {
		req, _ := http.NewRequest(http.MethodGet, l.opts.ModelURL, nil)
		if have > 0 {
			req.Header.Set("range", fmt.Sprintf("bytes=%d-", have))
		}
		res, err := http.DefaultClient.Do(req)
		if err != nil {
			return err
		}
		defer res.Body.Close()
		if res.StatusCode < 200 || res.StatusCode > 299 {
			return fmt.Errorf("HTTP %d", res.StatusCode)
		}
		resumed := have > 0 && res.StatusCode == 206
		flags := os.O_CREATE | os.O_WRONLY | os.O_TRUNC
		if resumed {
			flags = os.O_CREATE | os.O_WRONLY | os.O_APPEND
		} else {
			l.mu.Lock()
			*l.downloading = 0
			l.mu.Unlock()
		}
		out, err := os.OpenFile(part, flags, 0o644)
		if err != nil {
			return err
		}
		buf := make([]byte, 1<<20)
		for {
			n, readErr := res.Body.Read(buf)
			if n > 0 {
				if _, err := out.Write(buf[:n]); err != nil {
					out.Close()
					return err
				}
				l.mu.Lock()
				*l.downloading += int64(n)
				l.mu.Unlock()
			}
			if readErr == io.EOF {
				break
			}
			if readErr != nil {
				out.Close()
				return readErr
			}
		}
		if err := out.Close(); err != nil {
			return err
		}
		f, err := os.Open(part)
		if err != nil {
			return err
		}
		hash := sha256.New()
		_, err = io.Copy(hash, f)
		f.Close()
		if err != nil {
			return err
		}
		if hex.EncodeToString(hash.Sum(nil)) != l.opts.SHA256 {
			os.Remove(part)
			return fmt.Errorf("checksum mismatch; the partial file was removed")
		}
		return os.Rename(part, l.modelPath)
	}()
	l.mu.Lock()
	defer l.mu.Unlock()
	l.downloading = nil
	if err == nil {
		l.failures = 0
		l.logf("downloaded and verified")
		return
	}
	wait := downloadRetryMs[min(l.failures, len(downloadRetryMs)-1)]
	l.failures++
	l.logf("download failed (%s); retrying in %d min", err, int(math.Round(float64(wait)/60_000)))
	l.retry = time.AfterFunc(time.Duration(wait)*time.Millisecond, func() {
		l.mu.Lock()
		l.retry = nil
		l.mu.Unlock()
		l.Prepare()
	})
}

func (l *localModel) Health() LocalHealth {
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.downloading != nil {
		p := math.Min(1, float64(*l.downloading)/float64(l.opts.Bytes))
		return LocalHealth{State: "downloading", Progress: &p}
	}
	if !l.hasModel() || !l.hasServer() {
		return LocalHealth{State: "missing"}
	}
	if nowMs() < l.failedUntil {
		return LocalHealth{State: "failed"}
	}
	if l.server != nil {
		return LocalHealth{State: "running"}
	}
	return LocalHealth{State: "ready"}
}

func (l *localModel) Close() {
	close(l.stopIdle)
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.retry != nil {
		l.retry.Stop()
	}
	l.stopLocked()
}
