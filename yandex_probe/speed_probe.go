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

type CloudflareMeta struct {
	ClientIP string `json:"clientIp"`
	Country  string `json:"country"`
	City     string `json:"city"`
}

var countryNames = map[string]string{
	"AD": "Andorra",
	"AE": "United Arab Emirates",
	"AF": "Afghanistan",
	"AG": "Antigua and Barbuda",
	"AI": "Anguilla",
	"AL": "Albania",
	"AM": "Armenia",
	"AO": "Angola",
	"AQ": "Antarctica",
	"AR": "Argentina",
	"AS": "American Samoa",
	"AT": "Austria",
	"AU": "Australia",
	"AW": "Aruba",
	"AX": "Åland Islands",
	"AZ": "Azerbaijan",
	"BA": "Bosnia and Herzegovina",
	"BB": "Barbados",
	"BD": "Bangladesh",
	"BE": "Belgium",
	"BF": "Burkina Faso",
	"BG": "Bulgaria",
	"BH": "Bahrain",
	"BI": "Burundi",
	"BJ": "Benin",
	"BL": "Saint Barthélemy",
	"BM": "Bermuda",
	"BN": "Brunei Darussalam",
	"BO": "Bolivia, Plurinational State of",
	"BQ": "Bonaire, Sint Eustatius and Saba",
	"BR": "Brazil",
	"BS": "Bahamas",
	"BT": "Bhutan",
	"BV": "Bouvet Island",
	"BW": "Botswana",
	"BY": "Belarus",
	"BZ": "Belize",
	"CA": "Canada",
	"CC": "Cocos (Keeling) Islands",
	"CD": "Congo, The Democratic Republic of the",
	"CF": "Central African Republic",
	"CG": "Congo",
	"CH": "Switzerland",
	"CI": "Côte d'Ivoire",
	"CK": "Cook Islands",
	"CL": "Chile",
	"CM": "Cameroon",
	"CN": "China",
	"CO": "Colombia",
	"CR": "Costa Rica",
	"CU": "Cuba",
	"CV": "Cabo Verde",
	"CW": "Curaçao",
	"CX": "Christmas Island",
	"CY": "Cyprus",
	"CZ": "Czechia",
	"DE": "Germany",
	"DJ": "Djibouti",
	"DK": "Denmark",
	"DM": "Dominica",
	"DO": "Dominican Republic",
	"DZ": "Algeria",
	"EC": "Ecuador",
	"EE": "Estonia",
	"EG": "Egypt",
	"EH": "Western Sahara",
	"ER": "Eritrea",
	"ES": "Spain",
	"ET": "Ethiopia",
	"FI": "Finland",
	"FJ": "Fiji",
	"FK": "Falkland Islands (Malvinas)",
	"FM": "Micronesia, Federated States of",
	"FO": "Faroe Islands",
	"FR": "France",
	"GA": "Gabon",
	"GB": "United Kingdom",
	"GD": "Grenada",
	"GE": "Georgia",
	"GF": "French Guiana",
	"GG": "Guernsey",
	"GH": "Ghana",
	"GI": "Gibraltar",
	"GL": "Greenland",
	"GM": "Gambia",
	"GN": "Guinea",
	"GP": "Guadeloupe",
	"GQ": "Equatorial Guinea",
	"GR": "Greece",
	"GS": "South Georgia and the South Sandwich Islands",
	"GT": "Guatemala",
	"GU": "Guam",
	"GW": "Guinea-Bissau",
	"GY": "Guyana",
	"HK": "Hong Kong",
	"HM": "Heard Island and McDonald Islands",
	"HN": "Honduras",
	"HR": "Croatia",
	"HT": "Haiti",
	"HU": "Hungary",
	"ID": "Indonesia",
	"IE": "Ireland",
	"IL": "Israel",
	"IM": "Isle of Man",
	"IN": "India",
	"IO": "British Indian Ocean Territory",
	"IQ": "Iraq",
	"IR": "Iran, Islamic Republic of",
	"IS": "Iceland",
	"IT": "Italy",
	"JE": "Jersey",
	"JM": "Jamaica",
	"JO": "Jordan",
	"JP": "Japan",
	"KE": "Kenya",
	"KG": "Kyrgyzstan",
	"KH": "Cambodia",
	"KI": "Kiribati",
	"KM": "Comoros",
	"KN": "Saint Kitts and Nevis",
	"KP": "Korea, Democratic People's Republic of",
	"KR": "Korea, Republic of",
	"KW": "Kuwait",
	"KY": "Cayman Islands",
	"KZ": "Kazakhstan",
	"LA": "Lao People's Democratic Republic",
	"LB": "Lebanon",
	"LC": "Saint Lucia",
	"LI": "Liechtenstein",
	"LK": "Sri Lanka",
	"LR": "Liberia",
	"LS": "Lesotho",
	"LT": "Lithuania",
	"LU": "Luxembourg",
	"LV": "Latvia",
	"LY": "Libya",
	"MA": "Morocco",
	"MC": "Monaco",
	"MD": "Moldova, Republic of",
	"ME": "Montenegro",
	"MF": "Saint Martin (French part)",
	"MG": "Madagascar",
	"MH": "Marshall Islands",
	"MK": "North Macedonia",
	"ML": "Mali",
	"MM": "Myanmar",
	"MN": "Mongolia",
	"MO": "Macao",
	"MP": "Northern Mariana Islands",
	"MQ": "Martinique",
	"MR": "Mauritania",
	"MS": "Montserrat",
	"MT": "Malta",
	"MU": "Mauritius",
	"MV": "Maldives",
	"MW": "Malawi",
	"MX": "Mexico",
	"MY": "Malaysia",
	"MZ": "Mozambique",
	"NA": "Namibia",
	"NC": "New Caledonia",
	"NE": "Niger",
	"NF": "Norfolk Island",
	"NG": "Nigeria",
	"NI": "Nicaragua",
	"NL": "Netherlands",
	"NO": "Norway",
	"NP": "Nepal",
	"NR": "Nauru",
	"NU": "Niue",
	"NZ": "New Zealand",
	"OM": "Oman",
	"PA": "Panama",
	"PE": "Peru",
	"PF": "French Polynesia",
	"PG": "Papua New Guinea",
	"PH": "Philippines",
	"PK": "Pakistan",
	"PL": "Poland",
	"PM": "Saint Pierre and Miquelon",
	"PN": "Pitcairn",
	"PR": "Puerto Rico",
	"PS": "Palestine, State of",
	"PT": "Portugal",
	"PW": "Palau",
	"PY": "Paraguay",
	"QA": "Qatar",
	"RE": "Réunion",
	"RO": "Romania",
	"RS": "Serbia",
	"RU": "Russian Federation",
	"RW": "Rwanda",
	"SA": "Saudi Arabia",
	"SB": "Solomon Islands",
	"SC": "Seychelles",
	"SD": "Sudan",
	"SE": "Sweden",
	"SG": "Singapore",
	"SH": "Saint Helena, Ascension and Tristan da Cunha",
	"SI": "Slovenia",
	"SJ": "Svalbard and Jan Mayen",
	"SK": "Slovakia",
	"SL": "Sierra Leone",
	"SM": "San Marino",
	"SN": "Senegal",
	"SO": "Somalia",
	"SR": "Suriname",
	"SS": "South Sudan",
	"ST": "Sao Tome and Principe",
	"SV": "El Salvador",
	"SX": "Sint Maarten (Dutch part)",
	"SY": "Syrian Arab Republic",
	"SZ": "Eswatini",
	"TC": "Turks and Caicos Islands",
	"TD": "Chad",
	"TF": "French Southern Territories",
	"TG": "Togo",
	"TH": "Thailand",
	"TJ": "Tajikistan",
	"TK": "Tokelau",
	"TL": "Timor-Leste",
	"TM": "Turkmenistan",
	"TN": "Tunisia",
	"TO": "Tonga",
	"TR": "Türkiye",
	"TT": "Trinidad and Tobago",
	"TV": "Tuvalu",
	"TW": "Taiwan, Province of China",
	"TZ": "Tanzania, United Republic of",
	"UA": "Ukraine",
	"UG": "Uganda",
	"UM": "United States Minor Outlying Islands",
	"US": "United States",
	"UY": "Uruguay",
	"UZ": "Uzbekistan",
	"VA": "Holy See (Vatican City State)",
	"VC": "Saint Vincent and the Grenadines",
	"VE": "Venezuela, Bolivarian Republic of",
	"VG": "Virgin Islands, British",
	"VI": "Virgin Islands, U.S.",
	"VN": "Viet Nam",
	"VU": "Vanuatu",
	"WF": "Wallis and Futuna",
	"WS": "Samoa",
	"YE": "Yemen",
	"YT": "Mayotte",
	"ZA": "South Africa",
	"ZM": "Zambia",
	"ZW": "Zimbabwe",
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

func countryName(code string) string {
	code = strings.ToUpper(strings.TrimSpace(code))
	if name, ok := countryNames[code]; ok {
		return name
	}
	return code
}

func setGeo(res *Result, ip, countryCode, city, source string) bool {
	ip = strings.TrimSpace(ip)
	countryCode = strings.ToUpper(strings.TrimSpace(countryCode))
	city = strings.TrimSpace(city)

	if ip == "" || countryCode == "" || city == "" {
		return false
	}

	res.IP = ip
	res.CountryCode = countryCode
	res.Country = countryName(countryCode)
	res.City = city
	res.Flag = countryCodeEmoji(countryCode)
	res.Source = source
	return true
}

func geoFromHeaders(res *Result, h http.Header, source string) bool {
	return setGeo(
		res,
		h.Get("cf-meta-ip"),
		h.Get("cf-meta-country"),
		h.Get("cf-meta-city"),
		source,
	)
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
	req.Header.Set("User-Agent", "vpn-checker-ru-probe/4.0")
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

	// Cloudflare Speed often provides apparent-client metadata in the same
	// download response. Reuse it so many keys need no extra geo request.
	geoFromHeaders(&res, resp.Header, "cloudflare_speed_headers")

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

func runCloudflareHeaderFallback(parent context.Context, worker Worker, job Job, target string, timeout time.Duration) Result {
	res := Result{
		Key:    job.Key,
		Mode:   "geo",
		Source: "cloudflare_speed_header_fallback",
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
	req.Header.Set("User-Agent", "vpn-checker-ru-probe/4.0")
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
	_, _ = io.Copy(io.Discard, io.LimitReader(resp.Body, 4096))
	res.TotalMS = time.Since(start).Milliseconds()

	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		res.Error = fmt.Sprintf("cloudflare_header_fallback_http_%d", resp.StatusCode)
		return res
	}

	if !geoFromHeaders(&res, resp.Header, "cloudflare_speed_header_fallback") {
		res.Error = "cloudflare_header_fallback_missing_geo"
		return res
	}

	res.OK = true
	return res
}

func runGeo(parent context.Context, worker Worker, job Job, target, fallback string, timeout time.Duration) Result {
	res := Result{
		Key:    job.Key,
		Mode:   "geo",
		Source: "cloudflare_speed_meta",
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
	req.Header.Set("User-Agent", "vpn-checker-ru-probe/4.0")
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
			var payload CloudflareMeta
			if jsonErr := json.Unmarshal(body, &payload); jsonErr == nil {
				if setGeo(&res, payload.ClientIP, payload.Country, payload.City, "cloudflare_speed_meta") {
					res.OK = true
					return res
				}
				res.Error = "cloudflare_meta_missing_geo"
			} else if jsonErr != nil {
				res.Error = "cloudflare_meta_json: " + jsonErr.Error()
			}
		} else if readErr != nil {
			res.Error = "cloudflare_meta_read: " + readErr.Error()
		} else {
			res.Error = fmt.Sprintf("cloudflare_meta_http_%d", resp.StatusCode)
		}
	} else {
		res.TotalMS = time.Since(start).Milliseconds()
		res.Error = "cloudflare_meta_request: " + err.Error()
	}

	if fallback == "" {
		return res
	}

	fallbackRes := runCloudflareHeaderFallback(parent, worker, job, fallback, timeout)
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
