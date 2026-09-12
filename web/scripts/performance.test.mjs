import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, statSync } from 'node:fs';
import { resolve } from 'node:path';
import vm from 'node:vm';

const root = resolve(process.env.PERF_DIST || 'dist');
const html = (route) => readFileSync(resolve(root, route, 'index.html'), 'utf8');

for (const route of ['', 'blog', 'blog/apple-health-data-schema']) {
  test(`optimized logo is wired into ${route || '/'}`, () => {
    const page = html(route);
    const logo = page.match(/<img[^>]+alt="health4.ai"[^>]*>/)?.[0];
    assert.ok(logo, 'Rendered brand image exists');
    assert.match(logo, /srcset="[^"]+ 32w,[^"]+ 64w,[^"]+ 96w"/);
    assert.match(logo, /width="32"/);
    const src = logo.match(/src="([^"]+)"/)[1];
    assert.match(src, /\.webp$/);
    assert.ok(statSync(resolve(root, `.${src}`)).size < 4000);
  });
}

test('critical hero content has no entrance delay and reduced motion is supported', () => {
  const page = html('');
  assert.ok(!/class="hero-in/.test(page), 'Critical content must render without entrance animation');
  const css = [...page.matchAll(/href="([^"]+\.css)"/g)]
    .map((match) => readFileSync(resolve(root, `.${match[1]}`), 'utf8')).join('\n') + page;
  assert.ok(/prefers-reduced-motion/.test(css), 'Reduced-motion CSS is shipped');
  assert.ok(/stroke-dashoffset:0/.test(css), 'Reduced motion leaves ECG visible');
});

test('both waitlists retain explicit Apple consent and functional wiring', () => {
  const page = html('');
  for (const id of ['waitlist-form', 'waitlist-form-2', 'tf-consent-1', 'tf-consent-2']) {
    assert.ok(page.includes(`id="${id}"`), id);
  }
  assert.equal((page.match(/shared with Apple/g) || []).length, 2);
  assert.ok(page.includes('consent_testflight'));
  assert.ok(page.includes('waitlist_consent_toggled'));
  assert.ok(page.includes('Not a medical device'));
  assert.ok(page.includes('Supabase only'))
  // Neon and local Docker are NOT supported backends: the app signs in with Supabase Auth and writes
  // through a Supabase Edge Function, and no other ingest path exists. This used to assert those
  // panels were present, i.e. it guarded the false claim. It now guards against it returning.
  assert.ok(!page.includes('tab-neon') && !page.includes('tab-local'), 'Neon / local Docker setup panels must not return');
});

function waitlistFixture(status = 201) {
  const elements = new Map();
  const requests = [];
  const captured = [];
  for (const suffix of ['', '-2']) {
    const form = { handlers: {}, querySelectorAll: () => [] };
    form.addEventListener = (event, handler) => { form.handlers[event] = handler; };
    elements.set(`waitlist-form${suffix}`, form);
    elements.set(`email-input${suffix}`, { value: 'performance@example.invalid' });
    elements.set(`form-status${suffix}`, { textContent: '', style: {} });
  }
  for (const i of [1, 2]) {
    elements.set(`hp-${i}`, { value: '' });
    elements.set(`tf-consent-${i}`, {
      checked: false, addEventListener() {},
      form: elements.get(`waitlist-form${i === 1 ? '' : '-2'}`),
    });
  }
  const script = [...html('').matchAll(/<script[^>]*>([\s\S]*?)<\/script>/g)]
    .map((match) => match[1]).find((source) => source.includes('async function submitWaitlist'));
  assert.ok(script, 'Actual emitted form script exists');
  vm.runInNewContext(script, {
    document: { getElementById: (id) => elements.get(id) },
    window: { posthog: { capture: (...args) => captured.push(args) } },
    fetch: async (url, options) => {
      requests.push({ url, body: JSON.parse(options.body) });
      return { ok: status === 201, status };
    },
  });
  return { elements, requests, captured };
}

for (const [suffix, consentId, name] of [['', 'tf-consent-1', 'hero'], ['-2', 'tf-consent-2', 'bottom']]) {
  test(`${name} form emits explicit consent only to mocked fetch`, async () => {
    const fixture = waitlistFixture();
    fixture.elements.get(consentId).checked = name === 'bottom';
    await fixture.elements.get(`waitlist-form${suffix}`).handlers.submit({ preventDefault() {} });
    assert.equal(fixture.requests.length, 1);
    assert.equal(fixture.requests[0].body.consent_testflight, name === 'bottom');
    assert.equal(fixture.requests[0].body.consent_source, `web:${name}:v2`);
    assert.equal(fixture.elements.get(`form-status${suffix}`).textContent, "Received — we'll be in touch.");
    assert.equal(fixture.captured[0][0], 'waitlist_signup');
  });
}

test('duplicate with consent does not imply a beta invitation was created', async () => {
  const fixture = waitlistFixture(409);
  fixture.elements.get('tf-consent-1').checked = true;
  await fixture.elements.get('waitlist-form').handlers.submit({ preventDefault() {} });
  assert.equal(fixture.requests.length, 1);
  assert.match(fixture.elements.get('form-status').textContent, /Reply to our launch email/);
  assert.equal(fixture.captured[0][0], 'waitlist_duplicate');
});
