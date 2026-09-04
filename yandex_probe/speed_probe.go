package main

import (
	"bufio"
	"bytes"
	"crypto/rand"
	"encoding/binary"
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
	CascadeOK     bool    `json:"cascade_ok,omitempty"`
	FailedStage   string  `json:"failed_stage,omitempty"`
	CascadeTotalMS int64  `json:"cascade_total_ms,omitempty"`
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

func runHTTPCheck(parent context.Context, worker Worker, target string, expectedStatus int, timeout time.Duration) (bool, int, int64, string) {
	client, err := proxyClient(worker.Port, timeout)
	if err != nil {
		return false, 0, 0, err.Error()
	}

	ctx, cancel := context.WithTimeout(parent, timeout)
	defer cancel()

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, target, nil)
	if err != nil {
		return false, 0, 0, err.Error()
	}
	req.Header.Set("User-Agent", "Mozilla/5.0")
	req.Header.Set("Cache-Control", "no-cache")

	start := time.Now()
	resp, err := client.Do(req)
	elapsed := time.Since(start).Milliseconds()
	if err != nil {
		return false, 0, elapsed, err.Error()
	}
	defer resp.Body.Close()

	_, _ = io.Copy(io.Discard, io.LimitReader(resp.Body, 64*1024))

	if expectedStatus > 0 {
		if resp.StatusCode != expectedStatus {
			return false, resp.StatusCode, elapsed, fmt.Sprintf("http_status_%d", resp.StatusCode)
		}
	} else {
		if resp.StatusCode < 100 || resp.StatusCode > 599 {
			return false, resp.StatusCode, elapsed, fmt.Sprintf("invalid_http_status_%d", resp.StatusCode)
		}
	}

	return true, resp.StatusCode, elapsed, ""
}

func socks5Connect(parent context.Context, proxyPort int, host string, port int, timeout time.Duration) (net.Conn, error) {
	dialer := &net.Dialer{Timeout: timeout}

	ctx, cancel := context.WithTimeout(parent, timeout)
	defer cancel()

	conn, err := dialer.DialContext(ctx, "tcp", fmt.Sprintf("127.0.0.1:%d", proxyPort))
	if err != nil {
		return nil, err
	}

	ok := false
	defer func() {
		if !ok {
			_ = conn.Close()
		}
	}()



	hostBytes := []byte(host)
	if len(hostBytes) == 0 || len(hostBytes) > 255 {
		return nil, fmt.Errorf("invalid_host_length")
	}

	request := []byte{0x05, 0x01, 0x00, 0x03, byte(len(hostBytes))}
	request = append(request, hostBytes...)
	request = append(request, byte(port>>8), byte(port))

	if _, err = conn.Write(request); err != nil {
		return nil, err
	}

	header := make([]byte, 4)
	if _, err = io.ReadFull(conn, header); err != nil {
		return nil, err
	}

        if header[0] != 0x05 {
                return nil, fmt.Errorf("socks_bad_version_%d", header[0])
        }
        if header[1] != 0x00 {
                return nil, fmt.Errorf("socks_connect_reply_%d", header[1])
        }

        switch header[3] {
        case 0x01:
                rest := make([]byte, 4+2)
                if _, err = io.ReadFull(conn, rest); err != nil {
                        return nil, err
                }
        case 0x03:
                length := make([]byte, 1)
                if _, err = io.ReadFull(conn, length); err != nil {
                        return nil, err
                }
                rest := make([]byte, int(length[0])+2)
                if _, err = io.ReadFull(conn, rest); err != nil {
                        return nil, err
                }
        case 0x04:
                rest := make([]byte, 16+2)
                if _, err = io.ReadFull(conn, rest); err != nil {
                        return nil, err
                }
        default:
                return nil, fmt.Errorf("socks_bad_atyp_%d", header[3])
        }

        ok = true
        return conn, nil
}



func telegramReqPQOnce(parent context.Context, proxyPort int, host string, remotePort int, timeout time.Duration) (bool, int64, string) {
	start := time.Now()

	conn, err := socks5Connect(parent, proxyPort, host, remotePort, timeout)
	if err != nil {
		return false, time.Since(start).Milliseconds(), err.Error()
	}
	defer conn.Close()

	_ = conn.SetDeadline(time.Now().Add(timeout))

	nonce := make([]byte, 16)
	if _, err = rand.Read(nonce); err != nil {
		return false, time.Since(start).Milliseconds(), err.Error()
	}

	body := make([]byte, 20)
	binary.LittleEndian.PutUint32(body[0:4], 0xBE7E8EF1)
	copy(body[4:20], nonce)

	payload := make([]byte, 20+len(body))
	binary.LittleEndian.PutUint64(payload[8:16], uint64(time.Now().Unix())<<32)
	binary.LittleEndian.PutUint32(payload[16:20], uint32(len(body)))
	copy(payload[20:], body)

	if len(payload)%4 != 0 {
		return false, time.Since(start).Milliseconds(), "mtproto_payload_not_divisible_by_4"
	}

	words := len(payload) / 4
	if words < 1 || words > 0x7e {
		return false, time.Since(start).Milliseconds(), "mtproto_invalid_packet_size"
	}

	packet := append([]byte{0xef, byte(words)}, payload...)
	if _, err = conn.Write(packet); err != nil {
		return false, time.Since(start).Milliseconds(), err.Error()
	}

	first := make([]byte, 1)
	if _, err = io.ReadFull(conn, first); err != nil {
		return false, time.Since(start).Milliseconds(), err.Error()
	}

	var responseWords int
	if first[0] == 0x7f {
		more := make([]byte, 3)
		if _, err = io.ReadFull(conn, more); err != nil {
			return false, time.Since(start).Milliseconds(), err.Error()
		}
		responseWords = int(more[0]) | int(more[1])<<8 | int(more[2])<<16
	} else if first[0] >= 1 && first[0] <= 0x7e {
		responseWords = int(first[0])
	} else {
		return false, time.Since(start).Milliseconds(), fmt.Sprintf("mtproto_bad_length_byte_%02x", first[0])
	}

	responseLen := responseWords * 4
	if responseLen < 40 || responseLen > 4096 {
		return false, time.Since(start).Milliseconds(), fmt.Sprintf("mtproto_bad_response_size_%d", responseLen)
	}

	response := make([]byte, responseLen)
	if _, err = io.ReadFull(conn, response); err != nil {
		return false, time.Since(start).Milliseconds(), err.Error()
	}

	if !bytes.Equal(response[:8], make([]byte, 8)) {
		return false, time.Since(start).Milliseconds(), "mtproto_unexpected_encrypted_response"
	}

	bodyLen := int(binary.LittleEndian.Uint32(response[16:20]))
	if bodyLen < 36 || 20+bodyLen > len(response) {
		return false, time.Since(start).Milliseconds(), fmt.Sprintf("mtproto_bad_body_length_%d", bodyLen)
	}

	constructor := binary.LittleEndian.Uint32(response[20:24])
	if constructor != 0x05162463 {
		return false, time.Since(start).Milliseconds(), fmt.Sprintf("mtproto_bad_constructor_%08x", constructor)
	}

	if !bytes.Equal(response[24:40], nonce) {
		return false, time.Since(start).Milliseconds(), "mtproto_nonce_mismatch"
	}

	return true, time.Since(start).Milliseconds(), ""
}

func runTelegramMTProto(parent context.Context, proxyPort int, timeout time.Duration) (bool, int64, string) {
	endpoints := []string{
		"149.154.167.50",
		"149.154.167.51",
	}

	var errors []string
	var totalMS int64

	for _, host := range endpoints {
		ok, elapsed, errText := telegramReqPQOnce(parent, proxyPort, host, 443, timeout)
		totalMS += elapsed

		if ok {
			return true, totalMS, ""
		}

		errors = append(errors, host+":"+errText)
	}

	return false, totalMS, strings.Join(errors, ";")
}

func runCascade(parent context.Context, worker Worker, job Job) Result {
	res := Result{
		Key:  job.Key,
		Mode: "cascade",
	}

	start := time.Now()

	fail := func(stage string, errText string) Result {
		res.CascadeOK = false
		res.OK = false
		res.FailedStage = stage
		res.Error = errText
		res.CascadeTotalMS = time.Since(start).Milliseconds()
		return res
	}

	// 1. ChatGPT main: strict HTTP 200, maximum 5 seconds.
	if ok, status, _, errText := runHTTPCheck(
		parent,
		worker,
		"https://chatgpt.com/robots.txt",
		200,
		5*time.Second,
	); !ok {
		return fail("chatgpt_main", fmt.Sprintf("status=%d error=%s", status, errText))
	}

	// 2. ChatGPT Auth: any real HTTP response means TLS/HTTPS is reachable.
	if ok, status, _, errText := runHTTPCheck(
		parent,
		worker,
		"https://auth.openai.com/",
		0,
		9*time.Second,
	); !ok {
		return fail("chatgpt_auth", fmt.Sprintf("status=%d error=%s", status, errText))
	}

	// 3. ChatGPT Android: any real HTTP response.
	if ok, status, _, errText := runHTTPCheck(
		parent,
		worker,
		"https://android.chat.openai.com/",
		0,
		9*time.Second,
	); !ok {
		return fail("chatgpt_android", fmt.Sprintf("status=%d error=%s", status, errText))
	}

	// 4. YouTube generate_204: strict HTTP 204.
	if ok, status, _, errText := runHTTPCheck(
		parent,
		worker,
		"https://www.youtube.com/generate_204",
		204,
		5*time.Second,
	); !ok {
		return fail("youtube_generate_204", fmt.Sprintf("status=%d error=%s", status, errText))
	}

	// 5. Second independent YouTube HTTPS check: strict HTTP 200.
	if ok, status, _, errText := runHTTPCheck(
		parent,
		worker,
		"https://www.youtube.com/robots.txt",
		200,
		5*time.Second,
	); !ok {
		return fail("youtube_robots", fmt.Sprintf("status=%d error=%s", status, errText))
	}

	// 6. Telegram HTTPS: any real HTTP response.
	if ok, status, _, errText := runHTTPCheck(
		parent,
		worker,
		"https://venus.web.telegram.org/api",
		0,
		3*time.Second,
	); !ok {
		return fail("telegram_https", fmt.Sprintf("status=%d error=%s", status, errText))
	}

	// 7. Telegram MTProto: real req_pq/resPQ through Telegram DC.
	if ok, _, errText := runTelegramMTProto(
		parent,
		worker.Port,
		3*time.Second,
	); !ok {
		return fail("telegram_mtproto", errText)
	}

	res.OK = true
	res.CascadeOK = true
	res.CascadeTotalMS = time.Since(start).Milliseconds()
	return res
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

func runDelay(parent context.Context, controller string, job Job, target string, timeout time.Duration) Result {
	res := Result{
		Key:  job.Key,
		Mode: "delay",
	}

	ctx, cancel := context.WithTimeout(parent, timeout+2*time.Second)
	defer cancel()

	delayURL := strings.TrimRight(controller, "/") +
		"/proxies/" + url.PathEscape(job.Key) +
		"/delay?timeout=" + fmt.Sprintf("%d", timeout.Milliseconds()) +
		"&url=" + url.QueryEscape(target)

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, delayURL, nil)
	if err != nil {
		res.Error = err.Error()
		return res
	}

	client := &http.Client{Timeout: timeout + 2*time.Second}
	resp, err := client.Do(req)
	if err != nil {
		res.Error = err.Error()
		return res
	}
	defer resp.Body.Close()

	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		res.Error = fmt.Sprintf("delay_http_%d", resp.StatusCode)
		return res
	}

	var payload struct {
		Delay int64 `json:"delay"`
	}

	if err := json.NewDecoder(io.LimitReader(resp.Body, 64*1024)).Decode(&payload); err != nil {
		res.Error = "delay_json: " + err.Error()
		return res
	}

	if payload.Delay <= 0 {
		res.Error = "delay_invalid"
		return res
	}

	res.OK = true
	res.TotalMS = payload.Delay
	return res
}

func main() {
	jobsPath := flag.String("jobs", "", "JSON file with [{key}]")
	mode := flag.String("mode", "speed", "speed, geo or cascade")
	target := flag.String("url", "", "target URL")
	fallbackURL := flag.String("fallback-url", "", "optional fallback URL for geo mode")
	controller := flag.String("controller", "http://127.0.0.1:9090", "Mihomo controller URL")
	groupPrefix := flag.String("group-prefix", "SPEED-", "selector group prefix")
	basePort := flag.Int("base-port", 20000, "first mixed listener port")
	expectedBytes := flag.Int64("bytes", 524288, "expected download bytes")
	concurrency := flag.Int("concurrency", 8, "parallel workers/selectors")
	timeout := flag.Duration("timeout", 8*time.Second, "per-request timeout")
	flag.Parse()

	if *jobsPath == "" || ((*mode == "speed" || *mode == "geo") && *target == "") {
		fmt.Fprintln(os.Stderr, "jobs and url are required")
		os.Exit(2)
	}
	if *mode != "speed" && *mode != "geo" && *mode != "cascade" {
		fmt.Fprintln(os.Stderr, "mode must be speed, geo, cascade or delay")
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
} else if *mode == "delay" {
				results[item.Index] = runDelay(ctx, *controller, item.Job, *target, *timeout)
			} else if *mode == "cascade" {
				results[item.Index] = runCascade(ctx, worker, item.Job)
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
