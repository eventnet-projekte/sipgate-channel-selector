#!/usr/bin/env node
/**
 * POC: sipgate DOM Explorer
 *
 * Verbindet sich mit sipgate via CDP und zeigt alle gefundenen
 * Channel-Elemente im DOM — ohne etwas zu verändern.
 *
 * Vorher: sipgate mit Debug-Port starten:
 *   pkill -f sipgate; sleep 1; open -a "sipgate" --args --remote-debugging-port=9222
 *
 * Dann:
 *   node poc.js
 */

const CDP = require('chrome-remote-interface');
const http = require('http');

async function getTargets() {
  return new Promise((resolve, reject) => {
    http.get('http://localhost:9222/json', res => {
      let data = '';
      res.on('data', c => data += c);
      res.on('end', () => resolve(JSON.parse(data)));
    }).on('error', reject);
  });
}

async function main() {
  console.log('Connecting to sipgate on port 9222...\n');

  let targets;
  try {
    targets = await getTargets();
  } catch (e) {
    console.error('Cannot reach localhost:9222.');
    console.error('Start sipgate first with:\n');
    console.error('  pkill -f sipgate; sleep 1; open -a "sipgate" --args --remote-debugging-port=9222\n');
    process.exit(1);
  }

  console.log(`Found ${targets.length} target(s):`);
  targets.forEach(t => console.log(`  [${t.type}] ${t.title} — ${t.url}`));

  const target = targets.find(t => t.type === 'page' && !t.url.startsWith('devtools://'));
  if (!target) {
    console.error('\nNo page target found. Is sipgate fully loaded?');
    process.exit(1);
  }

  console.log(`\nUsing target: "${target.title}"\n`);

  const client = await CDP({ port: 9222, target: target.id });
  const { Runtime } = client;
  await Runtime.enable();

  const result = await Runtime.evaluate({
    expression: `
      (function() {
        const out = { byAria: [], byText: [], activeClasses: [] };

        // 1. All elements with aria-label containing "channel" keywords
        document.querySelectorAll('[aria-label]').forEach(el => {
          const label = el.getAttribute('aria-label');
          if (label) {
            out.byAria.push({
              tag: el.tagName,
              ariaLabel: label,
              classes: el.className,
              text: el.textContent?.trim().slice(0, 50)
            });
          }
        });

        // 2. Elements whose text is "Hotline" or "Persönlicher Channel"
        const keywords = ['Hotline', 'Persönlicher Channel', 'Personal Channel'];
        document.querySelectorAll('*').forEach(el => {
          if (el.children.length === 0 || el.children.length < 3) {
            const text = el.textContent?.trim();
            if (text && keywords.some(k => text.includes(k))) {
              out.byText.push({
                tag: el.tagName,
                classes: el.className,
                text: text.slice(0, 80),
                ariaLabel: el.getAttribute('aria-label'),
                role: el.getAttribute('role')
              });
            }
          }
        });

        // 3. What classes contain "active" or "selected"?
        document.querySelectorAll('[class*="active"], [class*="selected"], [aria-selected="true"], [aria-current]').forEach(el => {
          const text = el.textContent?.trim().slice(0, 50);
          if (text) {
            out.activeClasses.push({
              tag: el.tagName,
              classes: el.className,
              text,
              ariaSelected: el.getAttribute('aria-selected'),
              ariaCurrent: el.getAttribute('aria-current')
            });
          }
        });

        return JSON.stringify(out, null, 2);
      })()
    `,
    returnByValue: true,
  });

  const data = JSON.parse(result.result.value);

  console.log('=== Elements with aria-label ===');
  if (data.byAria.length === 0) {
    console.log('  (none found)');
  } else {
    data.byAria.forEach(el => {
      console.log(`  <${el.tag}> aria-label="${el.ariaLabel}"`);
      if (el.classes) console.log(`    classes: ${el.classes}`);
      if (el.text)    console.log(`    text:    ${el.text}`);
    });
  }

  console.log('\n=== Elements with text "Hotline" / "Persönlicher Channel" ===');
  if (data.byText.length === 0) {
    console.log('  (none found — app may still be loading, or text is different)');
  } else {
    data.byText.forEach(el => {
      console.log(`  <${el.tag}>`);
      console.log(`    text:      "${el.text}"`);
      console.log(`    classes:   ${el.classes || '(none)'}`);
      console.log(`    aria-label: ${el.ariaLabel || '(none)'}`);
      console.log(`    role:       ${el.role || '(none)'}`);
    });
  }

  console.log('\n=== Currently "active" elements ===');
  if (data.activeClasses.length === 0) {
    console.log('  (none found)');
  } else {
    data.activeClasses.slice(0, 20).forEach(el => {
      console.log(`  <${el.tag}> "${el.text}"`);
      console.log(`    classes: ${el.classes}`);
      if (el.ariaSelected) console.log(`    aria-selected: ${el.ariaSelected}`);
      if (el.ariaCurrent)  console.log(`    aria-current:  ${el.ariaCurrent}`);
    });
  }

  await client.close();
  console.log('\nDone. Use this info to refine the selectors in watcher.js.');
}

main().catch(err => {
  console.error('Error:', err.message);
  process.exit(1);
});
