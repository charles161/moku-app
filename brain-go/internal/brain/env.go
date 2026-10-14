package brain

import (
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"strconv"
	"strings"
)

// CredentialKeys are the only keys a credentials file may set (no paths, no options).
var CredentialKeys = []string{"JEV_VERCEL", "MOKU_GATEWAY_URL", "MOKU_ACCESS_TOKEN"}

// DevEnvPath is the development fallback for credentials: bunny/.env, found beside the brain (a development build
// runs the brain from build/brain-dev, where build/.env links to bunny/.env). MOKU_DEV_ENV overrides it.
func DevEnvPath() string {
	if p := os.Getenv("MOKU_DEV_ENV"); p != "" {
		return p
	}
	exe, err := os.Executable()
	if err != nil {
		return ""
	}
	return filepath.Join(filepath.Dir(exe), "..", ".env")
}

// LoadEnv loads the model credentials, never printing a value:
//  1. $MOKU_HOME/credentials.env (what Moku.app installs): its CredentialKeys win over the environment;
//  2. the environment;
//  3. the development .env: fills only what is still unset, and only the brain's own keys (CredentialKeys and MOKU_*).
//     bunny/.env holds other secrets too (a PostHog personal key); they stay out of this process and its children.
//
// A missing file is not an error. Safe to call more than once.
func LoadEnv(devEnvPath string) {
	credentials := readEnvFile(CredentialsPath())
	for _, key := range CredentialKeys {
		if value, ok := credentials[key]; ok {
			os.Setenv(key, value)
		}
	}
	if devEnvPath == "" {
		return
	}
	for key, value := range readEnvFile(devEnvPath) {
		if !slices.Contains(CredentialKeys, key) && !strings.HasPrefix(key, "MOKU_") {
			continue
		}
		if _, set := os.LookupEnv(key); !set {
			os.Setenv(key, value)
		}
	}
}

var (
	envLine  = regexp.MustCompile(`^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*?)\s*$`)
	envQuote = regexp.MustCompile(`^'(.*)'$|^"(.*)"$`)
)

// readEnvFile reads KEY=VALUE lines; an unreadable file is empty.
func readEnvFile(path string) map[string]string {
	values := map[string]string{}
	data, err := os.ReadFile(path)
	if err != nil {
		return values
	}
	for _, line := range regexp.MustCompile(`\r?\n`).Split(string(data), -1) {
		m := envLine.FindStringSubmatch(line)
		if m == nil {
			continue
		}
		value := m[2]
		if q := envQuote.FindStringSubmatch(value); q != nil {
			value = q[1] + q[2]
		}
		values[m[1]] = value
	}
	return values
}

// ModelAccess: how the brain reaches the models: a tester's token for the Moku proxy, its own gateway key, or neither.
func ModelAccess() string {
	if os.Getenv("MOKU_GATEWAY_URL") != "" && os.Getenv("MOKU_ACCESS_TOKEN") != "" {
		return "proxy"
	}
	if os.Getenv("JEV_VERCEL") != "" {
		return "key"
	}
	return "none"
}

// AccessToken: what the brain shows the models now (the relay's token, or the developer's own key), read fresh from
// credentials.env, so a token the app has just written (an invite typed in) is seen at once.
func AccessToken() string {
	LoadEnv(DevEnvPath())
	if ModelAccess() == "proxy" {
		return os.Getenv("MOKU_ACCESS_TOKEN")
	}
	return os.Getenv("JEV_VERCEL")
}

// MokuHome holds the database, the config overrides and the credentials. MOKU_HOME wins; default ~/.moku.
func MokuHome() string {
	if h := os.Getenv("MOKU_HOME"); h != "" {
		return h
	}
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".moku")
}

// DatabasePath: MOKU_DB wins (tests and smoke runs use a temp file).
func DatabasePath() string {
	if p, ok := os.LookupEnv("MOKU_DB"); ok {
		return p
	}
	return filepath.Join(MokuHome(), "moku.sqlite")
}

// ConfigPath: MOKU_CONFIG wins.
func ConfigPath() string {
	if p, ok := os.LookupEnv("MOKU_CONFIG"); ok {
		return p
	}
	return filepath.Join(MokuHome(), "config.json")
}

func CredentialsPath() string { return filepath.Join(MokuHome(), "credentials.env") }

// BrainTokenPath: the secret Moku.app and its brain share, so nothing else on this Mac can talk to the brain.
func BrainTokenPath(home string) string { return filepath.Join(home, "brain-token") }

var brainTokenShape = regexp.MustCompile(`^[0-9a-f]{64}$`)

// NewBrainToken: 32 random bytes, in hex.
func NewBrainToken() (string, error) {
	var raw [32]byte
	if _, err := rand.Read(raw[:]); err != nil {
		return "", err
	}
	return hex.EncodeToString(raw[:]), nil
}

// LoadBrainToken: what every request must carry ("Authorization: Bearer …") for the brain to answer it.
// MOKU_BRAIN_TOKEN (Moku.app hands its brain the token it uses) wins. Otherwise $MOKU_HOME/brain-token, made on first
// use by whichever of the app and the brain starts first (a brain started by hand finds the app's), and replaced if
// it's damaged. The home becomes owner-only: it holds screen text and this token.
func LoadBrainToken(home string) (string, error) {
	if given := strings.TrimSpace(os.Getenv("MOKU_BRAIN_TOKEN")); given != "" {
		if len(given) < 32 {
			return "", fmt.Errorf("MOKU_BRAIN_TOKEN is too short (32 characters at least)")
		}
		return given, nil
	}
	if err := os.MkdirAll(home, 0o700); err != nil {
		return "", err
	}
	if err := os.Chmod(home, 0o700); err != nil {
		return "", err
	}
	path := BrainTokenPath(home)
	if existing, ok := readBrainToken(path); ok {
		return existing, nil
	}
	token, err := NewBrainToken()
	if err != nil {
		return "", err
	}
	tmp, err := os.CreateTemp(home, ".brain-token-*")
	if err != nil {
		return "", err
	}
	defer os.Remove(tmp.Name())
	_, werr := tmp.WriteString(token + "\n")
	if cerr := tmp.Close(); werr != nil || cerr != nil {
		return "", fmt.Errorf("writing the brain token: %v %v", werr, cerr)
	}
	// A link never replaces a file: if the app got there first, its token is the one.
	if os.Link(tmp.Name(), path) == nil {
		return token, nil
	}
	if existing, ok := readBrainToken(path); ok {
		return existing, nil
	}
	if err := os.Rename(tmp.Name(), path); err != nil {
		return "", err
	}
	return token, nil
}

func readBrainToken(path string) (string, bool) {
	data, err := os.ReadFile(path)
	token := strings.TrimSpace(string(data))
	return token, err == nil && brainTokenShape.MatchString(token)
}

// BrainPort: --port N (or --port=N), else MOKU_BRAIN_PORT, else 8020. 0 lets the system pick a free port.
func BrainPort(args []string) (int, error) {
	raw, found := "", false
	for i, a := range args {
		if a == "--port" {
			if i+1 < len(args) {
				raw = args[i+1]
			}
			found = true
			break
		}
		if strings.HasPrefix(a, "--port=") {
			raw, found = strings.SplitN(a, "=", 2)[1], true
			break
		}
	}
	if !found {
		raw = os.Getenv("MOKU_BRAIN_PORT")
	}
	if raw == "" {
		return 8020, nil
	}
	port, err := strconv.Atoi(raw)
	if err != nil || port < 0 || port > 65535 {
		return 0, fmt.Errorf("not a port: %s", raw)
	}
	return port, nil
}

// ModelIDs, each overridable for experiments.
func ModelIDs() (judge, writer string) {
	judge, writer = "typesafe-ai/jev", "openai/gpt-6-luna"
	if v, ok := os.LookupEnv("MOKU_MODEL_JUDGE"); ok {
		judge = v
	}
	if v, ok := os.LookupEnv("MOKU_MODEL_WRITER"); ok {
		writer = v
	}
	return
}
