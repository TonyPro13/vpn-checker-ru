package main

import (
	"encoding/json"
	"bytes"
	"fmt"
	"net/http"
	"net/url"
	"time"
)

const (
	controllerURL   = "http://127.0.0.1:9090"
	autoGroup       = "AUTO"
	testURL         = "https://cp.cloudflare.com"
	checkInterval   = 2 * time.Minute
	fullEveryCycles = 30
	goodLimit       = 10
	goodLatencyMS   = 100
	switchGainMS    = 20
	pingTimeoutMS   = 5000
)

type groupInfo struct {
	Now string   `json:"now"`
	All []string `json:"all"`
}

type delayResponse struct {
	Delay int `json:"delay"`
}

func proxyDelay(name string) (int, error) {
	endpoint := controllerURL +
		"/proxies/" + url.PathEscape(name) +
		"/delay?timeout=" + fmt.Sprint(pingTimeoutMS) +
		"&url=" + url.QueryEscape(testURL)

	client := &http.Client{Timeout: 7 * time.Second}

	resp, err := client.Get(endpoint)
	if err != nil {
		return 0, err
	}
	defer resp.Body.Close()

	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return 0, fmt.Errorf("delay http %d", resp.StatusCode)
	}

	var result delayResponse
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return 0, err
	}
	if result.Delay <= 0 {
		return 0, fmt.Errorf("invalid delay")
	}

	return result.Delay, nil
}

func getGroup() (groupInfo, error) {
	var group groupInfo

	endpoint := controllerURL + "/proxies/" + url.PathEscape(autoGroup)
	client := &http.Client{Timeout: 5 * time.Second}

	resp, err := client.Get(endpoint)
	if err != nil {
		return group, err
	}
	defer resp.Body.Close()

	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return group, fmt.Errorf("group http %d", resp.StatusCode)
	}

	if err := json.NewDecoder(resp.Body).Decode(&group); err != nil {
		return group, err
	}
	if len(group.All) == 0 {
		return group, fmt.Errorf("AUTO group is empty")
	}

	return group, nil
}

func selectProxy(name string) error {
	endpoint := controllerURL + "/proxies/" + url.PathEscape(autoGroup)
	body, err := json.Marshal(map[string]string{"name": name})
	if err != nil {
		return err
	}

	req, err := http.NewRequest(http.MethodPut, endpoint, bytes.NewReader(body))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")

	client := &http.Client{Timeout: 5 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()

	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return fmt.Errorf("select http %d", resp.StatusCode)
	}
	return nil
}

func scanProxies(names []string, full bool, start int) (string, int, int, int, int) {
	if len(names) == 0 {
		return "", 0, 0, 0, 0
	}

	if start < 0 || start >= len(names) {
		start = 0
	}

	bestName := ""
	bestDelay := 0
	checked := 0
	good := 0
	index := start

	for checked < len(names) {
		name := names[index]
		delay, err := proxyDelay(name)
		checked++

		if err == nil {
			if bestDelay == 0 || delay < bestDelay {
				bestName = name
				bestDelay = delay
			}
			if delay < goodLatencyMS {
				good++
			}
		}

		index++
		if index >= len(names) {
			index = 0
		}

		if !full && good >= goodLimit {
			break
		}
	}

	return bestName, bestDelay, checked, good, index
}

func runCycle(full bool, start int) int {
	group, err := getGroup()
	if err != nil {
		fmt.Println("AUTO error:", err)
		return start
	}

	bestName, bestDelay, checked, good, next := scanProxies(group.All, full, start)
	mode := "short"
	if full {
		mode = "full"
	}

	fmt.Printf("scan mode=%s total=%d checked=%d good_under_%dms=%d best=%q best_delay=%dms current=%q next=%d\\n", mode, len(group.All), checked, goodLatencyMS, good, bestName, bestDelay, group.Now, next)

	if bestName == "" || bestDelay <= 0 {
		fmt.Println("no working proxy found in scan")
		return next
	}

	currentDelay, currentErr := proxyDelay(group.Now)
	if currentErr != nil {
		fmt.Printf("current proxy %q unavailable: %v; switching to %q (%dms)\\n", group.Now, currentErr, bestName, bestDelay)
		if err := selectProxy(bestName); err != nil {
			fmt.Println("select error:", err)
		}
		return next
	}

	if bestName != group.Now && currentDelay-bestDelay >= switchGainMS {
		fmt.Printf("switch %q (%dms) -> %q (%dms), gain=%dms\\n", group.Now, currentDelay, bestName, bestDelay, currentDelay-bestDelay)
		if err := selectProxy(bestName); err != nil {
			fmt.Println("select error:", err)
		}
	} else {
		fmt.Printf("keep %q current=%dms best=%dms\\n", group.Now, currentDelay, bestDelay)
	}

	return next
}

func main() {
	start := 0

	fmt.Println("initial full Mihomo latency scan")
	start = runCycle(true, start)

	ticker := time.NewTicker(checkInterval)
	defer ticker.Stop()

	cycle := 0
	for range ticker.C {
		cycle++
		full := cycle%fullEveryCycles == 0
		start = runCycle(full, start)
	}
}
