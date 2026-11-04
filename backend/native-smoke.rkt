#lang racket/base

;; Synthetic, selftest-only native GLZ1 consumer fixture. Never served in
;; normal product launches or included in the reviewed application schema.
;; All traffic stays local; no LLM account, network provider, or real keys.
(require glaze/api)

(provide native-smoke-html native-smoke-routes)

(define native-smoke-html
  #<<HTML
<!doctype html>
<html lang="en">
<head><meta charset="utf-8"><title>HD Smoke START</title>
<script src="/glaze/api.js"></script></head>
<body><main id="result">Native GLZ1 smoke running</main>
<script>
(async function () {
  function assert(ok, what) { if (!ok) throw new Error(what); }
  function result(ok, detail) {
    const text = (ok ? 'HD Smoke PASS' : 'HD Smoke FAIL') + (detail ? ': ' + detail : '');
    document.title = text;
    document.getElementById('result').textContent = text;
  }
  try {
    assert(window.glaze && typeof glaze.invoke === 'function', 'missing native client');
    const hello = await glaze.hello();
    assert(hello && hello.glz === 1 && Array.isArray(hello.routes) &&
           hello.routes.some((route) => route.method === 'GET' &&
                                        route.path === '/api/health') &&
           hello.routes.some((route) => route.method === 'POST' &&
                                        route.path === '/api/kv/set'), 'GLZ1 hello route manifest');
    const health = await glaze.invoke('api/health', {}, { method: 'GET' });
    assert(health && health.ok === true && typeof health.version === 'string', 'GET health');

    const key = '__glaze_packaged_smoke';
    await glaze.invoke('api/kv/set', { key, value: 'native-round-trip' }, { method: 'POST' });
    const saved = await glaze.invoke('api/kv/get', { key }, { method: 'POST' });
    assert(saved && saved.value === 'native-round-trip', 'typed invoke round trip');

    let invalidRejected = false;
    try {
      await glaze.invoke('api/kv/set', { key, value: 42 }, { method: 'POST' });
    } catch (e) {
      invalidRejected = e && e.code === 'invalid-args';
    }
    assert(invalidRejected, 'typed argument rejection');

    const chunks = [];
    const full = await glaze.invokeStream('api/__smoke/stream', {}, {
      onDelta: (chunk) => chunks.push(chunk)
    });
    assert(full === 'alpha-beta-gamma-' && chunks.join('') === full, 'native stream delivery');

    const controller = new AbortController();
    const pending = glaze.invokeStream('api/__smoke/slow', {}, {
      signal: controller.signal
    });
    setTimeout(() => controller.abort(), 400);
    let canceled = false;
    try { await pending; } catch (e) { canceled = String(e).includes('aborted'); }
    assert(canceled, 'native stream cancellation');
    result(true, '');
  } catch (e) {
    result(false, String(e && e.message || e).slice(0, 150));
  }
})();
</script></body></html>
HTML
  )

(define (native-smoke-routes)
  (list
   (GET "api/__smoke/stream"
        (lambda (_req)
          (streaming-response
           (lambda (out)
             (for ([chunk (in-list '("alpha-" "beta-" "gamma-"))])
               (display chunk out)
               (flush-output out)
               (sleep 0.05))))))
   (GET "api/__smoke/slow"
        (lambda (_req)
          (streaming-response
           (lambda (out)
             (for ([i (in-range 100)])
               (display "tick;" out)
               (flush-output out)
               (sleep 0.05))))))))
