(ns user
  (:require [myapp.core :as core]
            [ring.adapter.jetty :as jetty]))

;; ── REPL workflow ───────────────────────────────────────────────────
;; 1. bb dev          → starts nREPL
;; 2. Editor connect  → connect Calva / Cursive / CIDER to port 7888
;; 3. (start)         → eval this to boot the server
;; 4. Edit routes     → eval the changed defn in core.clj
;;                      The server picks up changes automatically
;;                      because we pass #'core/app (the var, not the value)
;; 5. (restart)       → only needed if you change server config (port etc.)

(defonce server (atom nil))

(defn start
  "Start the Jetty server. Safe to call repeatedly."
  []
  (when-not @server
    (reset! server
            (jetty/run-jetty #'core/app {:port 8080 :join? false}))
    (println "Server running → http://localhost:8080/health")))

(defn stop
  "Stop the running server."
  []
  (when @server
    (.stop @server)
    (reset! server nil)
    (println "Server stopped.")))

(defn restart
  "Stop then start."
  []
  (stop)
  (start))
