(async () => {
    const sleep = ms => new Promise(r => setTimeout(r, ms));
    let el = document.querySelector("tr[class*=row__]");
    let scrollEl = null;
    while (el) {
        if (el.scrollHeight > el.clientHeight + 10) { scrollEl = el; break; }
        el = el.parentElement;
    }

    const collected = new Map();
    function collectVisible() {
        const rows = [...document.querySelectorAll("tr[class*=row__]")];
        for (const r of rows) {
            if (!r.children[1] || r.children[1].tagName !== "TD") continue;
            const c = [...r.children].map(x => x.textContent.trim());
            const key = c[1] + "|" + c[8];
            const fresh = {
                name: c[1], vendor: c[2], ap: c[3], experience: c[5],
                tech: c[6], channel: c[7], ip: c[8], download: c[9],
            };
            const prev = collected.get(key);
            if (!prev) { collected.set(key, fresh); continue; }
            // merge: a non-empty field always wins, never let a blank overwrite a filled value
            for (const k of Object.keys(fresh)) {
                if (fresh[k]) prev[k] = fresh[k];
            }
        }
    }

    async function sweep(stepFraction, waitMs) {
        if (!scrollEl) { collectVisible(); return; }
        scrollEl.scrollTop = 0;
        await sleep(waitMs);
        collectVisible();
        const step = scrollEl.clientHeight * stepFraction;
        let pos = 0;
        while (pos < scrollEl.scrollHeight) {
            pos += step;
            scrollEl.scrollTop = pos;
            await sleep(waitMs);
            collectVisible();
        }
    }

    // two passes: a fast first sweep, then a slower settle sweep that fills in
    // any fields (esp. the AP/Connection column) that lazy-populate after the
    // row's other cells have already rendered.
    await sweep(0.8, 250);
    await sweep(0.8, 500);

    return JSON.stringify([...collected.values()]);
})()
