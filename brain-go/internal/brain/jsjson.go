package brain

import (
	"bytes"
	"encoding/json"
	"math"
	"math/big"
	"regexp"
	"strconv"
	"strings"
	"unicode/utf16"
	"unicode/utf8"
)

// The brain's prompts and stored model inputs are JSON written exactly as JavaScript's JSON.stringify writes it,
// so the models see the same bytes the TypeScript brain sent: keys in insertion order (structs keep field order,
// OMap keeps its order), no HTML escaping, U+2028 and U+2029 left as they are, and \b and \f in their short forms.

// KV is one key of an ordered object.
type KV struct {
	Key   string
	Value any
}

// OMap is a JSON object that keeps its keys in the order they were added (JavaScript objects do).
type OMap []KV

// Get returns the value for key, if present.
func (m OMap) Get(key string) (any, bool) {
	for _, kv := range m {
		if kv.Key == key {
			return kv.Value, true
		}
	}
	return nil, false
}

// Keys in order.
func (m OMap) Keys() []string {
	keys := make([]string, len(m))
	for i, kv := range m {
		keys[i] = kv.Key
	}
	return keys
}

// Set replaces a key's value in place, or adds it at the end.
func (m OMap) Set(key string, value any) OMap {
	for i, kv := range m {
		if kv.Key == key {
			m[i].Value = value
			return m
		}
	}
	return append(m, KV{key, value})
}

func (m OMap) MarshalJSON() ([]byte, error) {
	var b bytes.Buffer
	b.WriteByte('{')
	for i, kv := range m {
		if i > 0 {
			b.WriteByte(',')
		}
		key, err := marshalPlain(kv.Key)
		if err != nil {
			return nil, err
		}
		b.Write(key)
		b.WriteByte(':')
		value, err := marshalPlain(kv.Value)
		if err != nil {
			return nil, err
		}
		b.Write(value)
	}
	b.WriteByte('}')
	return b.Bytes(), nil
}

func marshalPlain(v any) ([]byte, error) {
	var b bytes.Buffer
	enc := json.NewEncoder(&b)
	enc.SetEscapeHTML(false)
	if err := enc.Encode(v); err != nil {
		return nil, err
	}
	return bytes.TrimSuffix(b.Bytes(), []byte("\n")), nil
}

// JSON is JSON.stringify(v).
func JSON(v any) string {
	out, err := marshalPlain(v)
	if err != nil {
		panic("brain: cannot write JSON: " + err.Error())
	}
	return string(jsEscapes(out))
}

// JSONIndent is JSON.stringify(v, null, indent) with an indent of `spaces` spaces.
func JSONIndent(v any, spaces int) string {
	var b bytes.Buffer
	if err := json.Indent(&b, []byte(JSON(v)), "", strings.Repeat(" ", spaces)); err != nil {
		panic("brain: cannot indent JSON: " + err.Error())
	}
	return b.String()
}

// jsEscapes turns Go's escapes into JavaScript's:   and   as the characters themselves, \u0008 as \b and
// \u000c as \f. Only escapes inside strings are touched; an escaped backslash is skipped whole.
func jsEscapes(in []byte) []byte {
	if !bytes.Contains(in, []byte(`\u`)) {
		return in
	}
	out := make([]byte, 0, len(in))
	for i := 0; i < len(in); i++ {
		c := in[i]
		if c != '\\' || i+1 >= len(in) {
			out = append(out, c)
			continue
		}
		next := in[i+1]
		if next == 'u' && i+6 <= len(in) {
			switch string(in[i+2 : i+6]) {
			case "2028":
				out = append(out, " "...)
				i += 5
				continue
			case "2029":
				out = append(out, " "...)
				i += 5
				continue
			case "0008":
				out = append(out, `\b`...)
				i += 5
				continue
			case "000c":
				out = append(out, `\f`...)
				i += 5
				continue
			}
		}
		out = append(out, c, next)
		i++
	}
	return out
}

// ToFixed is Number.prototype.toFixed(digits): the nearest value, and on an exact tie the one farther from zero
// (strconv would round a tie to even).
func ToFixed(x float64, digits int) string {
	exact := new(big.Float).SetFloat64(x).Text('f', 1100) // the float's exact decimal value
	if dot := strings.IndexByte(exact, '.'); dot >= 0 && dot+1+digits < len(exact) {
		if strings.TrimRight(exact[dot+1+digits:], "0") == "5" {
			scale := math.Pow(10, float64(digits))
			up := math.Ceil(math.Abs(x)*scale) / scale
			return strconv.FormatFloat(math.Copysign(up, x), 'f', digits, 64)
		}
	}
	return strconv.FormatFloat(x, 'f', digits, 64)
}

// Round is Math.round: halves go up (toward +infinity).
func Round(x float64) float64 { return math.Floor(x + 0.5) }

// ── Strings, measured and cut as JavaScript does (UTF-16 code units) ─────────────────────────────────────────

// Len16 is a string's .length.
func Len16(s string) int {
	n := 0
	for _, r := range s {
		if r >= 0x10000 {
			n += 2
		} else {
			n++
		}
	}
	return n
}

// Slice16 is s.slice(0, end) in UTF-16 code units. A cut through a surrogate pair drops the half (Go strings can't
// hold one; JavaScript would keep a lone surrogate).
func Slice16(s string, end int) string {
	if end <= 0 {
		return ""
	}
	n := 0
	for i, r := range s {
		w := 1
		if r >= 0x10000 {
			w = 2
		}
		if n+w > end {
			return s[:i]
		}
		n += w
	}
	return s
}

// Slice16From is s.slice(start) in UTF-16 code units.
func Slice16From(s string, start int) string {
	n := 0
	for i, r := range s {
		if n >= start {
			return s[i:]
		}
		if r >= 0x10000 {
			n += 2
		} else {
			n++
		}
	}
	return ""
}

// units16 is a string as UTF-16 code units (for index math like lastIndexOf).
func units16(s string) []uint16 { return utf16.Encode([]rune(s)) }

// from16 turns UTF-16 code units back into a string.
func from16(u []uint16) string { return string(utf16.Decode(u)) }

// JS whitespace (\s in a JavaScript regular expression), for patterns that must match it exactly.
const jsSpace = `[\t\n\v\f\r \x{00a0}\x{1680}\x{2000}-\x{200a}\x{2028}\x{2029}\x{202f}\x{205f}\x{3000}\x{feff}]`

var (
	spaceRun   = regexp.MustCompile(jsSpace + `+`)
	leadSpace  = regexp.MustCompile(`^` + jsSpace + `+`)
	trailSpace = regexp.MustCompile(jsSpace + `+$`)
)

// Trim is String.prototype.trim.
func Trim(s string) string { return trailSpace.ReplaceAllString(leadSpace.ReplaceAllString(s, ""), "") }

// OneLine collapses whitespace to single spaces and trims.
func OneLine(s string) string { return Trim(spaceRun.ReplaceAllString(s, " ")) }

// Clip cuts to max characters (UTF-16 units) with an ellipsis.
func Clip(s string, max int) string {
	if Len16(s) <= max {
		return s
	}
	return strings.TrimRightFunc(Slice16(s, max-1), isJSSpace) + "…"
}

func isJSSpace(r rune) bool {
	switch r {
	case '\t', '\n', '\v', '\f', '\r', ' ', 0x00a0, 0x1680, 0x2028, 0x2029, 0x202f, 0x205f, 0x3000, 0xfeff:
		return true
	}
	return r >= 0x2000 && r <= 0x200a
}

// validUTF8 replaces invalid bytes (JavaScript strings never hold them).
func validUTF8(s string) string {
	if utf8.ValidString(s) {
		return s
	}
	return strings.ToValidUTF8(s, "�")
}
