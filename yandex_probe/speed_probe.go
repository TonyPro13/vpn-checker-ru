package main

import (
	"bytes"
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
	Key string `json:"key"`
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

type Worker struct {
	ID        int
	GroupName string
	Port      int
}

func selectProxy(controller, group, proxyName string, timeout time.Duration) error {
	body, _ := json.Marshal(map[string]string{"name": proxyName})

	req, err := http.NewRequest(
		http.MethodPut,
		controller+"/proxies/"+url.PathEscape(group),
		bytes.NewReader(body),
	)
	if err != nil {
		return err
	}

	req.Header.Set("Content-Type", "application/json")

	client := &http.Client{Timeout: timeout}
	resp, err := client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusNoContent && (resp.StatusCode < 200 || resp.StatusCode >= 300) {
		data, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
		return fmt.Errorf("selector_http_%d: %s", resp.StatusCode, string(data))
	}

	return nil
}

func runDownload(parent context.Context, worker Worker, job Job, target string, expectedBytes int64, timeout time.Duration) Result {
	res := Result{Key: job.Key}

	proxyURL, err := url.Parse(fmt.Sprintf("http://127.0.0.1:%d", worker.Port))
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
	req.Header.Set("User-Agent", "vpn-checker-ru-speed-probe/2.0")
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
	jobsPath := flag.String("jobs", "", "JSON file with [{key}]")
	target := flag.String("url", "", "download URL")
	controller := flag.String("controller", "http://127.0.0.1:9090", "Mihomo controller URL")
	groupPrefix := flag.String("group-prefix", "SPEED-", "selector group prefix")
	basePort := flag.Int("base-port", 20000, "first mixed listener port")
	expectedBytes := flag.Int64("bytes", 524288, "expected download bytes")
	concurrency := flag.Int("concurrency", 8, "parallel workers/selectors")
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

	if len(jobs) == 0 {
		enc := json.NewEncoder(os.Stdout)
		_ = enc.Encode([]Result{})
		return
	}

	if *concurrency < 1 {
		*concurrency = 1
	}
	if *concurrency > len(jobs) {
		*concurrency = len(jobs)
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

		worker := Worker{
			ID:        w + 1,
			GroupName: fmt.Sprintf("%s%d", *groupPrefix, w+1),
			Port:      *basePort + w,
		}

		go func(worker Worker) {
			defer wg.Done()

			for item := range queue {
				if err := selectProxy(
					*controller,
					worker.GroupName,
					item.Job.Key,
					3*time.Second,
				); err != nil {
					results[item.Index] = Result{
						Key:   item.Job.Key,
						Error: "selector_switch_failed: " + err.Error(),
					}
					continue
				}

				// Tiny guard so the selector change is fully visible before opening
				// the connection through this worker's inbound.
				time.Sleep(20 * time.Millisecond)

				results[item.Index] = runDownload(
					ctx,
					worker,
					item.Job,
					*target,
					*expectedBytes,
					*timeout,
				)
			}
		}(worker)
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
