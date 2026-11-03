package main

// START stats OMIT
// Stats is what logscan reports about a log.
type Stats struct {
	Lines     int64
	Bytes     int64
	Status    [6]int64 // by class: Status[2] counts 2xx, ..., Status[5] 5xx
	Truncated int64    // lines longer than the line limit
	Malformed int64    // lines without a status field
	Sum       []byte   // SHA-256 of the input, with -sum
}

// END stats OMIT

// START add OMIT
func (s *Stats) add(line []byte) {
	s.Lines++
	s.Bytes += int64(len(line)) + 1
	if c := statusClass(line); c >= 1 && c <= 5 {
		s.Status[c]++
	} else {
		s.Malformed++
	}
}

// statusClass returns the first digit of the fifth space-separated field
// ("2" for "200"), without allocating.
func statusClass(line []byte) int {
	field := 0
	for i := range len(line) {
		if line[i] == ' ' {
			field++
			if field == 4 && i+1 < len(line) && line[i+1] >= '1' && line[i+1] <= '5' {
				return int(line[i+1] - '0')
			}
		}
	}
	return 0
}

// END add OMIT

// START merge OMIT
func (s *Stats) merge(o Stats) {
	s.Lines += o.Lines
	s.Bytes += o.Bytes
	s.Truncated += o.Truncated
	s.Malformed += o.Malformed
	for i := range s.Status {
		s.Status[i] += o.Status[i]
	}
}

// END merge OMIT
