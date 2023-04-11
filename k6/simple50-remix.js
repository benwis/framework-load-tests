import { sleep, check } from 'k6'
import http from 'k6/http'

export const options = {
    thresholds: { http_req_duration: ['p(95)<2000'] },
    scenarios: {
        Scenario_1: {
            executor: 'ramping-vus',
            gracefulStop: '30s',
            stages: [
                { target: 50, duration: '1m' },
                { target: 50, duration: '1m' },
                { target: 0, duration: '1m' },
                //{ target: 200, duration: '30s' },
            ],
		gracefulRampDown: '30s',
            exec: 'load_home',
        },
    },
}

export function load_home() {
    let response

    // HomePage
    response = http.get('http://10.0.0.4:8080/')
    check(response, { 'status equals 200': response => response.status.toString() === '200' })

    // Automatically added sleep
    sleep(1)
}

