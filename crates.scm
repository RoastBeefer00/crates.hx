(require (prefix-in helix. "helix/commands.scm"))
(require (prefix-in helix.static. "helix/static.scm"))
(require "helix/editor.scm")
(require "helix/misc.scm")
(require "helix/ext.scm")
(require-builtin helix/core/text)
(require-builtin steel/process)

;; ─── doc helpers ─────────────────────────────────────────────────────────────

(define (current-doc-id) (editor->doc-id (editor-focus)))

;; ─── string primitives ───────────────────────────────────────────────────────

(define (str-trim str)
  (define len (string-length str))
  (define s (let loop ([i 0])
    (if (or (>= i len) (not (char-whitespace? (string-ref str i)))) i (loop (+ i 1)))))
  (define e (let loop ([i (- len 1)])
    (if (or (< i 0) (not (char-whitespace? (string-ref str i)))) (+ i 1) (loop (- i 1)))))
  (if (>= s e) "" (substring str s e)))

(define (str-starts-with? str prefix)
  (define plen (string-length prefix))
  (and (>= (string-length str) plen)
       (string=? (substring str 0 plen) prefix)))

(define (str-search haystack needle)
  (define hlen (string-length haystack))
  (define nlen (string-length needle))
  (let loop ([i 0])
    (cond
      [(> (+ i nlen) hlen) #f]
      [(string=? (substring haystack i (+ i nlen)) needle) i]
      [else (loop (+ i 1))])))

;; ─── process helper ──────────────────────────────────────────────────────────

(define (with-stdout-piped cmd)
  (set-piped-stdout! cmd)
  cmd)

;; ─── version helpers ─────────────────────────────────────────────────────────

(define (strip-version-prefix str)
  (let loop ([i 0])
    (if (>= i (string-length str))
        ""
        (let ([ch (string-ref str i)])
          (if (or (char=? ch #\^) (char=? ch #\~) (char=? ch #\=)
                  (char=? ch #\>) (char=? ch #\<) (char=? ch #\space))
              (loop (+ i 1))
              (substring str i (string-length str)))))))

;; Parse "1.2.3" → (1 2 3). Strips pre-release suffixes.
(define (parse-semver str)
  (define clean
    (let loop ([i 0])
      (cond
        [(>= i (string-length str)) str]
        [(let ([ch (string-ref str i)])
           (or (char=? ch #\-) (char=? ch #\+)))
         (substring str 0 i)]
        [else (loop (+ i 1))])))
  (define parts '())
  (define cur "")
  (for-each
    (lambda (ch)
      (if (char=? ch #\.)
          (begin
            (let ([n (string->number cur)])
              (when n (set! parts (cons n parts))))
            (set! cur ""))
          (set! cur (string-append cur (string ch)))))
    (string->list clean))
  (let ([n (string->number cur)])
    (when n (set! parts (cons n parts))))
  (reverse parts))

;; Returns 'ok if major versions match (req is compatible with latest),
;; 'outdated if a new major is available, 'unknown otherwise.
(define (version-status req-str latest-str)
  (define req (parse-semver (strip-version-prefix req-str)))
  (define lat (parse-semver latest-str))
  (cond
    [(or (null? req) (null? lat)) 'unknown]
    [(= (car req) (car lat)) 'ok]
    [else 'outdated]))

;; ─── Cargo.toml parsing ──────────────────────────────────────────────────────

;; Strip `# comment` from end of a value string, respecting quotes.
(define (strip-inline-comment str)
  (define in-quote #f)
  (define end (string-length str))
  (let loop ([i 0])
    (when (< i (string-length str))
      (define ch (string-ref str i))
      (cond
        [(char=? ch #\") (set! in-quote (not in-quote)) (loop (+ i 1))]
        [(and (char=? ch #\#) (not in-quote)) (set! end i)]
        [else (loop (+ i 1))])))
  (str-trim (substring str 0 end)))

;; Extract version from `{ version = "x.y", ... }`.
(define (extract-table-version tbl)
  (define key "version")
  (define idx (str-search tbl key))
  (and idx
       (let* ([after (str-trim (substring tbl (+ idx (string-length key)) (string-length tbl)))]
              [_ (and (> (string-length after) 0) (char=? (string-ref after 0) #\=))]
              [after-eq (str-trim (substring after 1 (string-length after)))])
         (and (> (string-length after-eq) 0)
              (char=? (string-ref after-eq 0) #\")
              (let ([close (let loop ([i 1])
                             (cond [(>= i (string-length after-eq)) #f]
                                   [(char=? (string-ref after-eq i) #\") i]
                                   [else (loop (+ i 1))]))])
                (and close (substring after-eq 1 close)))))))

;; Parse one dependency line.  Returns (name . version-req) or #f.
(define (parse-dep-line line)
  (define t (str-trim line))
  (if (or (= (string-length t) 0) (char=? (string-ref t 0) #\#))
      #f
      (let ([eq (let loop ([i 0])
                  (cond [(>= i (string-length t)) #f]
                        [(char=? (string-ref t i) #\=) i]
                        [else (loop (+ i 1))]))])
        (and eq
             (let* ([name (str-trim (substring t 0 eq))]
                    [val  (strip-inline-comment
                           (str-trim (substring t (+ eq 1) (string-length t))))])
               (cond
                 ;; serde = "1.0"
                 [(and (>= (string-length val) 2)
                       (char=? (string-ref val 0) #\")
                       (char=? (string-ref val (- (string-length val) 1)) #\"))
                  (cons name (substring val 1 (- (string-length val) 1)))]
                 ;; tokio = { version = "1", ... }
                 [(and (> (string-length val) 0) (char=? (string-ref val 0) #\{))
                  (let ([ver (extract-table-version val)])
                    (and ver (cons name ver)))]
                 [else #f]))))))

(define *dep-section-headers*
  (list "[dependencies]" "[dev-dependencies]" "[build-dependencies]"
        "[workspace.dependencies]"))

;; Returns list of (name version-req line-num) for all deps in current rope.
(define (parse-cargo-deps rope)
  (define n (rope-len-lines rope))
  (define result '())
  (define in-deps #f)
  (let loop ([i 0])
    (when (< i n)
      (define s (rope->string (rope->line rope i)))
      (define t (str-trim s))
      (cond
        [(member t *dep-section-headers*)
         (set! in-deps #t)]
        [(and (> (string-length t) 0)
              (char=? (string-ref t 0) #\[)
              (not (str-starts-with? t "[[")))
         (set! in-deps #f)]
        [in-deps
         (define entry (parse-dep-line s))
         (when entry
           (set! result (cons (list (car entry) (cdr entry) i) result)))])
      (loop (+ i 1))))
  result)

;; ─── crates.io ───────────────────────────────────────────────────────────────

(define (extract-max-stable-version json)
  (define key "\"max_stable_version\":\"")
  (define idx (str-search json key))
  (and idx
       (let ([vs (+ idx (string-length key))])
         (let loop ([i vs])
           (cond
             [(>= i (string-length json)) #f]
             [(char=? (string-ref json i) #\") (substring json vs i)]
             [else (loop (+ i 1))])))))

(define (fetch-latest-version name)
  (define url (string-append "https://crates.io/api/v1/crates/" name))
  (with-handler
    (lambda (_) #f)
    (~> (command "curl" (list "-sf" "--max-time" "10"
                              "-A" "crates.hx/0.1 (helix plugin)"
                              url))
        with-stdout-piped
        spawn-process
        Ok->value
        wait->stdout
        Ok->value
        extract-max-stable-version)))

;; ─── state ───────────────────────────────────────────────────────────────────

;; All active hint ids: list of (first-line last-line) pairs
(define *hint-ids* '())

;; Resolve add-typed-inlay-hint at load time via eval so older helix builds
;; (which lack the binding) don't get a compile-time FreeIdentifier error.
(define *typed-hint-fn*
  (with-handler (lambda (_) #f) (eval 'add-typed-inlay-hint)))

(define (add-hint! pos text kind)
  (if *typed-hint-fn*
      (*typed-hint-fn* pos text kind)
      (add-inlay-hint pos text)))

;; ─── core ────────────────────────────────────────────────────────────────────

(define (clear-hints!)
  (for-each
    (lambda (id)
      (with-handler (lambda (_) #f)
        (remove-inlay-hint-by-id (car id) (cadr id))))
    *hint-ids*)
  (set! *hint-ids* '()))

(define (is-cargo-toml? doc-id)
  (define path (editor-document->path doc-id))
  (and path
       (let ([p (string-length path)]
             [s "Cargo.toml"])
         (and (>= p (string-length s))
              (string=? (substring path (- p (string-length s)) p) s)))))

;; Fetch all deps in parallel (one thread per crate) and return results.
;; Each result is (name version-req line-num latest-version-or-#f).
(define (fetch-all-parallel deps)
  (define threads
    (map (lambda (dep)
           (spawn-native-thread
             (lambda ()
               (list (car dep) (cadr dep) (caddr dep)
                     (fetch-latest-version (car dep))))))
         deps))
  (map thread-join! threads))

;; Char index of the newline (or end-of-string) at the end of line N (0-based).
;; Mirrors oil.hx's line-end-char-index — safe, no rope API involved.
(define (line-end-char lines n)
  (let loop ([i 0] [pos 0])
    (if (= i n)
        (+ pos (string-length (list-ref lines i)))
        (loop (+ i 1) (+ pos (string-length (list-ref lines i)) 1)))))

;; Apply fetched results as inlay hints on doc-id (called on main thread).
(define (apply-hints! doc-id results)
  (with-handler
    (lambda (err)
      (set-status! (string-append "crates.hx error: " (to-string err))))
    (define r (editor->text doc-id))
    (when r
      (define full-text (rope->string r))
      (define text-lines (split-many full-text "\n"))
      (define n-lines (length text-lines))
      (define n-fetched (length (filter (lambda (r) (cadddr r)) results)))
      (for-each
        (lambda (res)
          (with-handler
            (lambda (err)
              (set-status! (string-append "crates.hx hint-err: " (to-string err))))
            (define req    (cadr  res))
            (define line   (caddr res))
            (define latest (cadddr res))
            (when (and latest (< line n-lines))
              (define hint-pos (line-end-char text-lines line))
              (define status (version-status req latest))
              (define text
                (cond
                  [(eq? status 'ok)       (string-append " ✓ " latest)]
                  [(eq? status 'outdated) (string-append " ⚠ " latest " available")]
                  [else                   (string-append " ? " latest)]))
              (define kind
                (cond
                  [(eq? status 'ok)       "type"]
                  [(eq? status 'outdated) "parameter"]
                  [else                   "other"]))
              (define id (add-hint! hint-pos text kind))
              (when id (set! *hint-ids* (cons id *hint-ids*))))))
        (sort results (lambda (a b) (< (caddr a) (caddr b)))))
      (set-status! (string-append "crates.hx: done ("
                                  (number->string n-fetched) "/"
                                  (number->string (length results))
                                  " fetched, "
                                  (number->string (length *hint-ids*))
                                  " hint-ids)")))))

;; Kick off a parallel fetch for doc-id/deps and apply hints when done.
(define (fetch-and-apply! doc-id deps)
  (spawn-native-thread
    (lambda ()
      (define results (fetch-all-parallel deps))
      (hx.with-context (lambda () (apply-hints! doc-id results))))))

;; ─── public commands ─────────────────────────────────────────────────────────

;;@doc
;; Fetch and display crates.io version hints for the current Cargo.toml.
(define (crates-show-hints)
  (define doc-id (current-doc-id))
  (unless (is-cargo-toml? doc-id)
    (set-status! "crates.hx: not a Cargo.toml")
    (return! (void)))

  (define rope (editor->text doc-id))
  (unless rope
    (set-status! "crates.hx: could not read buffer")
    (return! (void)))

  (define deps (parse-cargo-deps rope))
  (when (null? deps)
    (set-status! "crates.hx: no crates.io dependencies found")
    (return! (void)))

  (clear-hints!)
  (set-status!
    (string-append "crates.hx: fetching " (number->string (length deps)) " versions..."))
  (fetch-and-apply! doc-id deps))

;;@doc
;; Remove crates.hx version hints from the current buffer.
(define (crates-clear-hints)
  (clear-hints!)
  (set-status! "crates.hx: cleared"))

;;@doc
;; Register a hook so crates-show-hints runs automatically on document open.
(define (enable-crates-auto!)
  (register-hook 'document-opened
    (lambda (doc-id)
      (when (is-cargo-toml? doc-id)
        (define rope (editor->text doc-id))
        (when rope
          (define deps (parse-cargo-deps rope))
          (unless (null? deps)
            (clear-hints!)
            (fetch-and-apply! doc-id deps)))))))

(provide crates-show-hints crates-clear-hints enable-crates-auto!)
