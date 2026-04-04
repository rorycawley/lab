(ns myapp.core
  (:require [reitit.ring :as ring]
            [ring.adapter.jetty :as jetty]
            [ring.util.response :as resp]
            [iapetos.core :as prometheus]
            [iapetos.collector.ring :as ring-metrics]
            [iapetos.collector.jvm :as jvm-metrics])
  (:gen-class))

;; ── Prometheus registry ─────────────────────────────────────────────
;; Exposes: HTTP request latency/count + JVM heap/GC/threads
;; Scraped by Alloy via the prometheus.io/scrape pod annotation.

(defonce registry
  (-> (prometheus/collector-registry)
      (ring-metrics/initialize)
      (jvm-metrics/initialize)))

;; ── Routes ──────────────────────────────────────────────────────────
;; wrap-metrics with {:path "/metrics"} auto-serves the Prometheus
;; endpoint — no manual route needed.

(def app
  (-> (ring/ring-handler
        (ring/router
          [["/health" {:get (fn [_]
                              (-> (resp/response "{\"status\":\"ok\"}")
                                  (resp/content-type "application/json")))}]
           ["/hello"  {:get (fn [_]
                              (-> (resp/response "{\"message\":\"Hello from myapp!\"}")
                                  (resp/content-type "application/json")))}]])
        (ring/create-default-handler))
      (ring-metrics/wrap-metrics registry {:path "/metrics"})))

;; ── Entrypoint ──────────────────────────────────────────────────────

(defn -main [& _args]
  (let [port (Integer/parseInt (or (System/getenv "PORT") "8080"))]
    (println (str "Starting myapp on port " port))
    (jetty/run-jetty #'app {:port port :join? true})))
