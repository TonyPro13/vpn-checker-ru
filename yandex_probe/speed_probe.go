package main

import (
	"bufio"
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
	"strings"
	"sync"
	"time"
)

type Job struct {
	Key string `json:"key"`
}

type Result struct {
	Key         string  `json:"key"`
	OK          bool    `json:"ok"`
	Mode        string  `json:"mode"`
	HTTPStatus  int     `json:"http_status,omitempty"`
	Bytes       int64   `json:"bytes,omitempty"`
	TotalMS     int64   `json:"total_ms"`
	TTFBMS      int64   `json:"ttfb_ms,omitempty"`
	BodyMS      int64   `json:"body_ms,omitempty"`
	Mbps        float64 `json:"mbps,omitempty"`
	IP          string  `json:"ip,omitempty"`
	Country     string  `json:"country,omitempty"`
	CountryCode string  `json:"country_code,omitempty"`
	City        string  `json:"city,omitempty"`
	Flag        string  `json:"flag,omitempty"`
	Source      string  `json:"source,omitempty"`
	Error       string  `json:"error,omitempty"`
}

type Worker struct {
	ID        int
	GroupName string
	Port      int
}

type IPWhoResponse struct {
	IP          string `json:"ip"`
	Success     bool   `json:"success"`
	Message     string `json:"message"`
	Country     string `json:"country"`
	CountryCode string `json:"country_code"`
	City        string `json:"city"`
	Flag        struct {
		Emoji string `json:"emoji"`
	} `json:"flag"`
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

func proxyClient(port int, timeout time.Duration) (*http.Client, error) {
	proxyURL, err := url.Parse(fmt.Sprintf("http://127.0.0.1:%d", port))
	if err != nil {
		return nil, err
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

	return &http.Client{
		Transport: transport,
		Timeout:   timeout,
	}, nil
}

func runSpeed(parent context.Context, worker Worker, job Job, target string, expectedBytes int64, timeout time.Duration) Result {
	res := Result{Key: job.Key, Mode: "speed"}

	client, err := proxyClient(worker.Port, timeout)
	if err != nil {
		res.Error = err.Error()
		return res
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
	req.Header.Set("User-Agent", "vpn-checker-ru-probe/3.0")
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

func countryCodeEmoji(code string) string {
	code = strings.ToUpper(strings.TrimSpace(code))
	if len(code) != 2 {
		return "🌐"
	}
	runes := []rune(code)
	if runes[0] < 'A' || runes[0] > 'Z' || runes[1] < 'A' || runes[1] > 'Z' {
		return "🌐"
	}
	return string([]rune{
		0x1F1E6 + (runes[0] - 'A'),
		0x1F1E6 + (runes[1] - 'A'),
	})
}

func runCloudflareFallback(parent context.Context, worker Worker, job Job, target string, timeout time.Duration) Result {
	res := Result{
		Key:    job.Key,
		Mode:   "geo",
		Source: "cloudflare_trace_fallback",
		City:   "Unknown",
	}

	client, err := proxyClient(worker.Port, timeout)
	if err != nil {
		res.Error = err.Error()
		return res
	}

	ctx, cancel := context.WithTimeout(parent, timeout)
	defer cancel()

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, target, nil)
	if err != nil {
		res.Error = err.Error()
		return res
	}
	req.Header.Set("User-Agent", "vpn-checker-ru-probe/3.0")
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

	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		res.TotalMS = time.Since(start).Milliseconds()
		res.Error = fmt.Sprintf("fallback_http_status_%d", resp.StatusCode)
		return res
	}

	scanner := bufio.NewScanner(io.LimitReader(resp.Body, 64*1024))
	values := map[string]string{}
	for scanner.Scan() {
		line := scanner.Text()
		if idx := strings.IndexByte(line, '='); idx > 0 {
			values[line[:idx]] = line[idx+1:]
		}
	}
	res.TotalMS = time.Since(start).Milliseconds()

	if err := scanner.Err(); err != nil {
		res.Error = err.Error()
		return res
	}

	res.IP = strings.TrimSpace(values["ip"])
	res.CountryCode = strings.ToUpper(strings.TrimSpace(values["loc"]))
	res.Country = res.CountryCode
	res.Flag = countryCodeEmoji(res.CountryCode)

	if res.IP == "" {
		res.Error = "fallback_missing_ip"
		return res
	}

	res.OK = true
	return res
}

func runGeo(parent context.Context, worker Worker, job Job, target, fallback string, timeout time.Duration) Result {
	res := Result{
		Key:    job.Key,
		Mode:   "geo",
		Source: "ipwho.is",
	}

	client, err := proxyClient(worker.Port, timeout)
	if err != nil {
		res.Error = err.Error()
		return res
	}

	ctx, cancel := context.WithTimeout(parent, timeout)
	defer cancel()

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, target, nil)
	if err != nil {
		res.Error = err.Error()
		return res
	}
	req.Header.Set("User-Agent", "vpn-checker-ru-probe/3.0")
	req.Header.Set("Accept", "application/json")
	req.Header.Set("Cache-Control", "no-cache")

	start := time.Now()
	resp, err := client.Do(req)
	if err == nil {
		res.HTTPStatus = resp.StatusCode
		body, readErr := io.ReadAll(io.LimitReader(resp.Body, 256*1024))
		resp.Body.Close()
		res.TotalMS = time.Since(start).Milliseconds()

		if readErr == nil && resp.StatusCode >= 200 && resp.StatusCode < 300 {
			var payload IPWhoResponse
			if jsonErr := json.Unmarshal(body, &payload); jsonErr == nil && payload.Success && payload.IP != "" {
				res.OK = true
				res.IP = payload.IP
				res.Country = strings.TrimSpace(payload.Country)
				res.CountryCode = strings.ToUpper(strings.TrimSpace(payload.CountryCode))
				res.City = strings.TrimSpace(payload.City)
				res.Flag = strings.TrimSpace(payload.Flag.Emoji)

				if res.Flag == "" {
					res.Flag = countryCodeEmoji(res.CountryCode)
				}
				if res.Country == "" {
					res.Country = res.CountryCode
				}
				if res.City == "" {
					res.City = "Unknown"
				}
				return res
			} else if jsonErr != nil {
				res.Error = "ipwho_json: " + jsonErr.Error()
			} else {
				res.Error = "ipwho_unsuccessful: " + payload.Message
			}
		} else if readErr != nil {
			res.Error = "ipwho_read: " + readErr.Error()
		} else {
			res.Error = fmt.Sprintf("ipwho_http_%d", resp.StatusCode)
		}
	} else {
		res.TotalMS = time.Since(start).Milliseconds()
		res.Error = "ipwho_request: " + err.Error()
	}

	if fallback == "" {
		return res
	}

	fallbackRes := runCloudflareFallback(parent, worker, job, fallback, timeout)
	if fallbackRes.OK {
		return fallbackRes
	}

	if res.Error == "" {
		res.Error = fallbackRes.Error
	} else if fallbackRes.Error != "" {
		res.Error = res.Error + "; fallback: " + fallbackRes.Error
	}
	return res
}

func main() {
	jobsPath := flag.String("jobs", "", "JSON file with [{key}]")
	mode := flag.String("mode", "speed", "speed or geo")
	target := flag.String("url", "", "target URL")
	fallbackURL := flag.String("fallback-url", "", "optional fallback URL for geo mode")
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
	if *mode != "speed" && *mode != "geo" {
		fmt.Fprintln(os.Stderr, "mode must be speed or geo")
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
						Mode:  *mode,
						Error: "selector_switch_failed: " + err.Error(),
					}
					continue
				}

				time.Sleep(20 * time.Millisecond)

				if *mode == "geo" {
					results[item.Index] = runGeo(
						ctx,
						worker,
						item.Job,
						*target,
						*fallbackURL,
						*timeout,
					)
				} else {
					results[item.Index] = runSpeed(
						ctx,
						worker,
						item.Job,
						*target,
						*expectedBytes,
						*timeout,
					)
				}
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
