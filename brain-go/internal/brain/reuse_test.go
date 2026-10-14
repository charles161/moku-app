package brain

import "testing"

func TestJaccardOfScreenWords(t *testing.T) {
	cases := []struct {
		a, b string
		want float64
	}{
		{"Fix the login bug", "fix THE login bug!", 1},
		{"Fix the login bug", "Lunch plans for Friday", 0},
		{"alpha beta gamma delta", "alpha beta gamma epsilon", 3.0 / 5},
		{"a b c", "", 1}, // no word of three letters on either side
		{"நன்றி வணக்கம்", "நன்றி வணக்கம்", 1},
	}
	for _, c := range cases {
		if got := jaccard(wordSet(&c.a), wordSet(&c.b)); got != c.want {
			t.Errorf("jaccard(%q, %q) = %v, want %v", c.a, c.b, got, c.want)
		}
	}
	text := "chat with the team about the launch"
	if similarWords(nil, wordSet(&text), 0.5) || !similarWords(nil, nil, 0.5) {
		t.Errorf("text appearing is a big change; no text on either side is the same screen")
	}
}
