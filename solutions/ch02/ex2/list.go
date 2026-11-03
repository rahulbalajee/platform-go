// START page OMIT

package platformapi

import (
	"context"
	"iter"
	"net/url"
	"strconv"
)

// page is the wire shape of every list response.
type page[T any] struct {
	Items         []T    `json:"items"`
	NextPageToken string `json:"next_page_token"`
}

// list returns an iterator over every item of a collection. It fetches a
// page only when the consumer has used up the previous one, so breaking
// out of the loop stops the requests. A failed fetch yields the error
// once, with a zero item, and ends the iteration.
func (c *Client) list[T any](ctx context.Context, q url.Values,
	opts []CallOption, path ...string) iter.Seq2[T, error] {

	return func(yield func(T, error) bool) {
		r := newRequest("GET", opts, path...)
		r.query = q.Clone() // url.Values.Clone is new in Go 1.27
		if r.query == nil {
			r.query = url.Values{}
		}
		if r.call.pageSize > 0 {
			r.query.Set("page_size", strconv.Itoa(r.call.pageSize))
		}
		for {
			p, err := c.call[page[T]](ctx, r)
			if err != nil {
				var zero T
				yield(zero, err)
				return
			}
			for _, item := range p.Items {
				if !yield(item, nil) {
					return // the consumer broke out of the loop
				}
			}
			if p.NextPageToken == "" {
				return
			}
			r.query.Set("page_token", p.NextPageToken)
		}
	}
}

// END page OMIT

// START collect OMIT

// Collect drains seq into a slice. It stops at the first error and
// returns it together with the items collected so far.
func Collect[T any](seq iter.Seq2[T, error]) ([]T, error) {
	var out []T
	for item, err := range seq {
		if err != nil {
			return out, err
		}
		out = append(out, item)
	}
	return out, nil
}

// END collect OMIT

// START take OMIT

// Take returns an iterator over at most the first n items of seq. It
// stops ranging over seq once it has yielded n items, so a paginated
// list fetches no page it does not need. An error from seq is passed on
// and, like every error from the SDK's iterators, ends the sequence.
func Take[T any](seq iter.Seq2[T, error], n int) iter.Seq2[T, error] {
	return func(yield func(T, error) bool) {
		if n <= 0 {
			return // ranging over seq at all could send a request
		}
		taken := 0
		for item, err := range seq {
			if !yield(item, err) || err != nil {
				return
			}
			if taken++; taken == n {
				return
			}
		}
	}
}

// END take OMIT
