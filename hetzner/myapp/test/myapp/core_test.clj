(ns myapp.core-test
  (:require [clojure.test :refer [deftest is testing]]
            [myapp.core :as core]
            [ring.mock.request :as mock]))

;; Ring mock adapter — test the handler directly without starting a server.
;; This is fast (milliseconds) and doesn't need a port.

(deftest health-endpoint-test
  (testing "/health returns 200 with status ok"
    (let [response (core/app (mock/request :get "/health"))]
      (is (= 200 (:status response)))
      (is (clojure.string/includes? (:body response) "ok")))))

(deftest hello-endpoint-test
  (testing "/hello returns 200"
    (let [response (core/app (mock/request :get "/hello"))]
      (is (= 200 (:status response))))))

(deftest metrics-endpoint-test
  (testing "/metrics returns 200 with prometheus format"
    (let [response (core/app (mock/request :get "/metrics"))]
      (is (= 200 (:status response)))
      ;; Prometheus metrics contain the HELP and TYPE lines
      (is (clojure.string/includes? (:body response) "http_requests")))))

(deftest not-found-test
  (testing "unknown route returns 404"
    (let [response (core/app (mock/request :get "/nonexistent"))]
      (is (= 404 (:status response))))))
