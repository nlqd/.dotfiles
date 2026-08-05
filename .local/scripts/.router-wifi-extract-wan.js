(() => {
    function valueAfterLabel(label) {
        const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
        let node;
        while (node = walker.nextNode()) {
            if (node.textContent.trim() === label) {
                const sib = node.parentElement.nextElementSibling;
                if (sib) return sib.textContent.trim();
            }
        }
        return null;
    }

    const ispEl = document.querySelector("[data-testid=side-panel-trigger]");
    const ispText = ispEl && ispEl.parentElement ? ispEl.parentElement.textContent.trim() : "";
    const ispMatch = ispText.match(/^(.*?)(\d+)%$/);

    return JSON.stringify({
        uptime: valueAfterLabel("System Uptime"),
        monthlyUsage: valueAfterLabel("Monthly Data Usage"),
        ispName: ispMatch ? ispMatch[1] : null,
        ispQuality: ispMatch ? parseInt(ispMatch[2], 10) : null,
    });
})()
