package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptrace"
	"net/url"
	"os"
	"sort"
	"sync"
	"time"
)

type Job struct {
	Key  string `json:"key"`
	Port int    `json:"port"`
}

type Result struct {
	Key        string  `json:"key"`
	OK         bool    `json:"ok"`
	HTTPStatus int     `json:"http_status,omitempty"`
	Bytes      int64   `json:"bytes"`
	TotalMS    int64   `json:"total_ms"`
	TTFBMS     int64   `json:"ttfb_ms,omitempty"`
	BodyMS     int64   `json:"body_ms,omitempty"`
	Mbps       float64 `json:"mbps,omitempty"`
	Error      string  `json:"error,omitempty"`
}

func runJob(parent context.Context, job Job, target string, expectedBytes int64, timeout time.Duration) Result {
	res := Result{Key: job.Key}

	proxyURL, err := url.Parse(fmt.Sprintf("http://127.0.0.1:%d", job.Port))
	if err != nil {
		res.Error = err.Error()
		return res
	}

	dialer := &net.Dialer{
		Timeout:   4 * time.Second,
		KeepAlive: 0,
	}

	transport := &http.Transport{
		Proxy:                 http.ProxyURL(proxyURL),
		DialContext:           dialer.DialContext,
		ForceAttemptHTTP2:     false,
		DisableKeepAlives:     true,
		TLSHandshakeTimeout:   4 * time.Second,
		ResponseHeaderTimeout: timeout,
	}

	client := &http.Client{
		Transport: transport,
		Timeout:   timeout,
	}

	ctx, cancel := context.WithTimeout(parent, timeout)
	defer cancel()

	var firstByte time.Time
	trace := &httptrace.ClientTrace{
		GotFirstResponseByte: func() {
			firstByte = time.Now()
		},
	}
	ctx = httptrace.WithClientTrace(ctx, trace)

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, target, nil)
	if err != nil {
		res.Error = err.Error()
		return res
	}
	req.Header.Set("User-Agent", "vpn-checker-ru-speed-probe/1.0")
	req.Header.Set("Cache-Control", "no-cache")

	start := time.Now()
	resp, err := client.Do(req)
	if err != nil {
		res.TotalMS = time.Since(start).Milliseconds()
		res.Error = err.Error()
		return res
	}
	defer resp.Body.Close()

	res.HTTPStatus = resp.StatusCode

	n, copyErr := io.Copy(io.Discard, resp.Body)
	end := time.Now()

	res.Bytes = n
	res.TotalMS = end.Sub(start).Milliseconds()

	if !firstByte.IsZero() {
		res.TTFBMS = firstByte.Sub(start).Milliseconds()
		bodyDur := end.Sub(firstByte)
		res.BodyMS = bodyDur.Milliseconds()
		if bodyDur > 0 {
			res.Mbps = float64(n*8) / bodyDur.Seconds() / 1_000_000
		}
	}

	if copyErr != nil {
		res.Error = copyErr.Error()
		return res
	}

	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		res.Error = fmt.Sprintf("http_status_%d", resp.StatusCode)
		return res
	}

	if expectedBytes > 0 && n < expectedBytes {
		res.Error = fmt.Sprintf("short_download_%d_of_%d", n, expectedBytes)
		return res
	}

	res.OK = true
	return res
}

func main() {
	jobsPath := flag.String("jobs", "", "JSON file with [{key,port}]")
	target := flag.String("url", "", "download URL")
	expectedBytes := flag.Int64("bytes", 524288, "expected download bytes")
	concurrency := flag.Int("concurrency", 8, "parallel requests")
	timeout := flag.Duration("timeout", 8*time.Second, "per-request timeout")
	flag.Parse()

	if *jobsPath == "" || *target == "" {
		fmt.Fprintln(os.Stderr, "jobs and url are required")
		os.Exit(2)
	}

	data, err := os.ReadFile(*jobsPath)
	if err != nil {
		panic(err)
	}

	var jobs []Job
	if err := json.Unmarshal(data, &jobs); err != nil {
		panic(err)
	}

	if *concurrency < 1 {
		*concurrency = 1
	}

	results := make([]Result, len(jobs))
	type indexedJob struct {
		Index int
		Job   Job
	}

	queue := make(chan indexedJob)
	var wg sync.WaitGroup
	ctx := context.Background()

	for w := 0; w < *concurrency; w++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for item := range queue {
				results[item.Index] = runJob(
					ctx,
					item.Job,
					*target,
					*expectedBytes,
					*timeout,
				)
			}
		}()
	}

	for i, job := range jobs {
		queue <- indexedJob{Index: i, Job: job}
	}
	close(queue)
	wg.Wait()

	sort.SliceStable(results, func(i, j int) bool {
		return results[i].Key < results[j].Key
	})

	enc := json.NewEncoder(os.Stdout)
	enc.SetEscapeHTML(false)
	if err := enc.Encode(results); err != nil {
		panic(err)
	}
}
