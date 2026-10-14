package brain

import (
	"encoding/json"
	"fmt"
	"log"
	"math"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"strings"
	"sync"
	"time"
)

// LoadConfig: DefaultConfig merged with ~/.moku/config.json (or MOKU_CONFIG), read on every call so a timing can be
// tuned by editing the file. A bad value ignores the whole file (one warning per distinct problem), so a typo never
// half-applies. A key this brain doesn't know is skipped with a warning: it's a newer Moku's, after the person went back
// to an older one, and ignoring the whole file then forgot their name and Breaks & Water.
func LoadConfig(path string) CompanionConfig {
	data, err := os.ReadFile(path)
	if err != nil {
		return DefaultConfig
	}
	raw, err := decodeAny(data)
	if err != nil {
		warnOnce(path + " is not valid JSON; using defaults")
		return DefaultConfig
	}
	m, ok := raw.(map[string]any)
	if !ok {
		warnOnce(fmt.Sprintf("%s ignored ((root): Invalid input: expected object, received %s); using defaults", path, kindOf(raw)))
		return DefaultConfig
	}
	// A companion that's no longer offered (Yuzu the cat, retired 2026-10-04) falls back to Moku; the rest of the
	// file (the name, the drift timings) is kept.
	if c, ok := m["companion"].(string); ok && !slices.Contains(Companions, c) {
		warnOnce(fmt.Sprintf("%s: companion %q isn't offered any more; Moku keeps you company", path, c))
		delete(m, "companion")
	}
	// The drift ladder's timings are one tuned behaviour now (2026-10-04): a file that still holds them is read without
	// them, and keeps everything else.
	for _, key := range RetiredConfigKeys {
		delete(m, key)
	}
	for _, key := range sortedKeys(m) {
		if !slices.Contains(ConfigKeys, key) {
			warnOnce(fmt.Sprintf("%s: %q isn't a setting this Moku knows (a newer one's?); skipped", path, key))
			delete(m, key)
		}
	}
	var problems []string
	for _, key := range sortedKeys(m) {
		if msg := configValueProblem(key, m[key]); msg != "" {
			problems = append(problems, key+": "+msg)
		}
	}
	if len(problems) > 0 {
		warnOnce(fmt.Sprintf("%s ignored (%s); using defaults", path, strings.Join(problems, "; ")))
		return DefaultConfig
	}
	return applyOverrides(DefaultConfig, m)
}

func sortedKeys(m map[string]any) []string {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	slices.Sort(keys)
	return keys
}

// configValueProblem: why this key and value can't be a config override ("" when it can).
func configValueProblem(key string, value any) string {
	if !slices.Contains(ConfigKeys, key) {
		return "Unrecognized key"
	}
	if key == "userName" {
		if _, ok := value.(string); !ok {
			return "Invalid input: expected string, received " + kindOf(value)
		}
		return ""
	}
	if key == "companion" {
		if s, ok := value.(string); !ok || !slices.Contains(Companions, s) {
			return `Invalid option: expected one of "` + strings.Join(Companions, `"|"`) + `"`
		}
		return ""
	}
	n, ok := value.(json.Number)
	if !ok {
		return "Invalid input: expected number, received " + kindOf(value)
	}
	x, err := n.Float64()
	if slices.Contains(OffableKeys, key) {
		if err != nil || math.IsInf(x, 0) || x < 0 {
			return "Too small: expected number to be >=0"
		}
		return ""
	}
	if err != nil || math.IsInf(x, 0) || x <= 0 {
		return "Too small: expected number to be >0"
	}
	return ""
}

// OffableKeys can be 0, which turns them off (Settings › Breaks & Water): the drink of water and the break suggestion.
// The app's engine skips a reminder whose interval is 0; every other timing must be positive.
var OffableKeys = []string{"drinkEverySec", "breakAfterSec"}

// RetiredConfigKeys were Settings' drift pace (Gentle, Normal, Quick and your own minutes) and how often the companion
// looks up and smiles. There is one behaviour now, the old Normal: the defaults below. The keys are no longer accepted (PUT /v1/config says "Unrecognized key"), a file
// that still holds them loads without them, and ClearRetiredConfig takes them out of the file once, at start.
var RetiredConfigKeys = []string{"graceSec", "annoyedAfterSec", "standUpAfterSec", "askAfterSec", "smileEverySec"}

// ClearRetiredConfig takes the retired keys out of the overrides file, keeping every other key (the name, the
// companion, Breaks & Water). It returns the keys it removed; a file without any is left untouched.
func ClearRetiredConfig(path string) []string {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil
	}
	parsed, err := decodeAny(data)
	m, ok := parsed.(map[string]any)
	if err != nil || !ok {
		return nil
	}
	var cleared []string
	for _, key := range RetiredConfigKeys {
		if _, present := m[key]; present {
			cleared = append(cleared, key)
		}
	}
	if len(cleared) == 0 {
		return nil
	}
	if _, err := SaveConfig(map[string]any{}, path); err != nil {
		return nil
	}
	return cleared
}

func applyOverrides(base CompanionConfig, m map[string]any) CompanionConfig {
	data, _ := json.Marshal(base)
	var merged map[string]any
	json.Unmarshal(data, &merged)
	for k, v := range m {
		if n, ok := v.(json.Number); ok {
			f, _ := n.Float64()
			merged[k] = f
		} else {
			merged[k] = v
		}
	}
	out := base
	data, _ = json.Marshal(merged)
	json.Unmarshal(data, &out)
	return out
}

var configLine = regexp.MustCompile(`^[^\n\r\t]*$`)

// ParseConfigPatch is PUT /v1/config's body: any subset of CompanionConfig (at least one key), every value valid;
// unknown keys are refused. The name must be a name: trimmed, one line, 1–60 characters.
func ParseConfigPatch(body []byte) (map[string]any, []Issue, error) {
	raw, err := decodeAny(body)
	if err != nil {
		return nil, nil, err
	}
	c := &checker{}
	m, ok := raw.(map[string]any)
	if !ok {
		c.fail("", "Invalid input: expected object, received %s", kindOf(raw))
		return nil, c.issues, nil
	}
	patch := map[string]any{}
	known := 0
	for _, key := range sortedKeys(m) {
		if slices.Contains(ConfigKeys, key) {
			known++
		}
		value := m[key]
		if key == "userName" {
			s, isString := value.(string)
			if !isString {
				c.fail(key, "Invalid input: expected string, received %s", kindOf(value))
				continue
			}
			name := Trim(s)
			switch {
			case Len16(name) < 1:
				c.fail(key, "Too small: expected string to have >=1 characters")
			case Len16(name) > 60:
				c.fail(key, "Too big: expected string to have <=60 characters")
			case !configLine.MatchString(name):
				c.fail(key, "one line")
			default:
				patch[key] = name
			}
			continue
		}
		if msg := configValueProblem(key, value); msg != "" {
			if msg == "Unrecognized key" {
				c.fail("", `Unrecognized key: "%s"`, key)
			} else {
				c.fail(key, "%s", msg)
			}
			continue
		}
		if key == "companion" {
			patch[key] = value
			continue
		}
		f, _ := value.(json.Number).Float64()
		patch[key] = f
	}
	// As zod's refine: it looks at the keys the schema knows (valid or not), so unknown keys alone also say this.
	if known == 0 {
		c.fail("", "no keys to set")
	}
	if len(c.issues) > 0 {
		return nil, c.issues, nil
	}
	return patch, nil, nil
}

var configWrite sync.Mutex

// SaveConfig merges `patch` into the overrides file and returns the config as served from then on. The other keys
// stay. The write is atomic (a temp file, then a rename). A file holding keys the loader would refuse is kept as
// config.json.bad and only its valid keys carry over.
func SaveConfig(patch map[string]any, path string) (CompanionConfig, error) {
	configWrite.Lock()
	defer configWrite.Unlock()
	valid, dropped, raw := readOverrides(path)
	if dropped != "" {
		if err := os.WriteFile(path+".bad", raw, 0o600); err == nil {
			warnOnce(fmt.Sprintf("%s had keys the loader refused (%s); kept a copy as %s.bad", path, dropped, path))
		}
	}
	for k, v := range patch {
		valid[k] = v
	}
	// Written in the schema's key order, two-space indented, as the TypeScript brain wrote it.
	var merged OMap
	for _, key := range ConfigKeys {
		if v, ok := valid[key]; ok {
			if n, isNumber := v.(json.Number); isNumber {
				f, _ := n.Float64()
				v = f
			}
			merged = append(merged, KV{key, v})
		}
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return CompanionConfig{}, err
	}
	temp := fmt.Sprintf("%s.%d.%d.tmp", path, os.Getpid(), time.Now().UnixMilli())
	content := JSONIndent(merged, 2) + "\n"
	if len(merged) == 0 {
		content = "{}\n"
	}
	if err := os.WriteFile(temp, []byte(content), 0o600); err != nil {
		os.Remove(temp)
		return CompanionConfig{}, err
	}
	os.Chmod(temp, 0o600)
	if err := os.Rename(temp, path); err != nil {
		os.Remove(temp)
		return CompanionConfig{}, err
	}
	return LoadConfig(path), nil
}

// readOverrides: the file's overrides split into the keys the schema accepts and a note on the ones it doesn't.
func readOverrides(path string) (map[string]any, string, []byte) {
	valid := map[string]any{}
	raw, err := os.ReadFile(path)
	if err != nil {
		return valid, "", nil
	}
	parsed, err := decodeAny(raw)
	if err != nil {
		return valid, "not valid JSON", raw
	}
	m, ok := parsed.(map[string]any)
	if !ok {
		return valid, "not an object", raw
	}
	var dropped []string
	for _, key := range ordered(raw, m) {
		if slices.Contains(RetiredConfigKeys, key) {
			continue // retired, not refused: it's left out of the next write, and no .bad copy is made for it
		}
		if configValueProblem(key, m[key]) == "" {
			valid[key] = m[key]
		} else if retired, isString := m[key].(string); key == "companion" && isString && retired != "" {
			// A companion that's no longer offered (LoadConfig falls back to Moku): dropped on purpose, nothing to keep a copy for.
		} else {
			dropped = append(dropped, key)
		}
	}
	return valid, strings.Join(dropped, ", "), raw
}

// ordered: an object's keys in the order they appear in its JSON text.
func ordered(raw []byte, m map[string]any) []string {
	dec := json.NewDecoder(strings.NewReader(string(raw)))
	var keys []string
	depth, expectKey := 0, false
	for {
		tok, err := dec.Token()
		if err != nil {
			break
		}
		if d, isDelim := tok.(json.Delim); isDelim {
			if d == '{' || d == '[' {
				depth++
			} else {
				depth--
			}
			if depth == 1 {
				expectKey = true // the top object opened, or a nested value just ended
			}
			continue
		}
		if depth != 1 {
			continue
		}
		if expectKey {
			if key, ok := tok.(string); ok {
				if _, known := m[key]; known && !slices.Contains(keys, key) {
					keys = append(keys, key)
				}
			}
			expectKey = false
		} else {
			expectKey = true
		}
	}
	return keys
}

var (
	warned   = map[string]bool{}
	warnedMu sync.Mutex
)

func warnOnce(message string) {
	warnedMu.Lock()
	defer warnedMu.Unlock()
	if warned[message] {
		return
	}
	warned[message] = true
	log.Printf("moku config: %s", message)
}
