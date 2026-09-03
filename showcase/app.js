const flowContent = [
  {
    kicker: "RESP READER / 01",
    code: "*3\\r\\n$5\\r\\nS_SET…",
    title: "Parse the wire without losing the stream.",
    copy: "A buffered stateful reader decodes RESP frames from TCP, preserves incomplete data across reads, and detects queued commands for the batch path.",
    points: ["Incremental socket reads", "Protocol errors become structured responses", "Buffered input unlocks pipelining"]
  },
  {
    kicker: "DISPATCHER / 02",
    code: "resolve_locks(command)",
    title: "Turn a command into an execution plan.",
    copy: "A flat command table resolves the handler while the dispatcher owns transaction state, lock scope, AOF policy, and normal versus batched execution.",
    points: ["One routing path for normal and transactional work", "Read/write intent is explicit", "Command lookup is constant-time"]
  },
  {
    kicker: "SHARD LOCKS / 03",
    code: "sort(unique(shard_ids))",
    title: "Synchronize the smallest safe key range.",
    copy: "A command locks one shard, a stable set of shards, or the whole keyspace. Multi-key commands always acquire sorted shard IDs so two clients cannot form a lock cycle.",
    points: ["Concurrent readers", "Exclusive writers", "Sorted acquisition prevents deadlocks"]
  },
  {
    kicker: "HYPERCOMMAND / 04",
    code: "rmodify!(dict, key, sincr!)",
    title: "Centralize policy, delegate behavior.",
    copy: "Hypercommands implement reusable key semantics—lookup, type validation, TTL, create/replace behavior, and cleanup—then call a small operation for the concrete data type.",
    points: ["Less duplicated command code", "Consistent expiry semantics", "New operations compose existing policy"]
  },
  {
    kicker: "TYPED STORE / 05",
    code: "Dict{String, RadishElement{T}}",
    title: "Keep concrete values concrete.",
    copy: "Strings, custom linked lists, and sets live in separate typed dictionaries. A compact global index locates each key and enforces one-key-one-type behavior.",
    points: ["No Any on the value hot path", "O(1) key type lookup", "One registry extends store-wide behavior"]
  }
];

const decisions = {
  typed: {
    file: "store.jl",
    title: "Concrete types on the hot path",
    copy: "Each data type has its own dictionary while one global index enforces one-key-one-type semantics. Julia can specialize operations without boxing values behind Any.",
    code: `<span class="kw">mutable struct</span> <span class="type">RadishStore</span>\n  strings::<span class="type">Dict</span>{String, RadishElement{String}}\n  lists::<span class="type">Dict</span>{String, RadishElement{DLinkedList}}\n  sets::<span class="type">Dict</span>{String, RadishElement{Set{String}}}\n  keytype::<span class="type">Dict</span>{String, Symbol}\n<span class="kw">end</span>`
  },
  locks: {
    file: "simple_fair_sharded_lock.jl",
    title: "Writer preference without lock tricks",
    copy: "Each shard tracks active readers, an active writer, and waiting writers behind one Condition. Once a writer queues, new readers wait—favoring correctness and explainability.",
    code: `<span class="kw">while</span> shard.writer_active ||\n      shard.active_readers > 0\n  wait(shard.cond)\n<span class="kw">end</span>\nshard.writer_active = <span class="type">true</span>`
  },
  persistence: {
    file: "dirty_tracker.jl",
    title: "O(1) handoff from hot path to syncer",
    copy: "The syncer swaps dirty maps under a tiny critical section. Writers immediately continue on fresh maps while snapshot work proceeds independently on the previous set.",
    code: `<span class="kw">lock</span>(tracker.lock) <span class="kw">do</span>\n  modified = tracker.modified\n  deleted = tracker.deleted\n  tracker.modified = <span class="type">Dict</span>()\n  tracker.deleted = <span class="type">Dict</span>()\n  <span class="kw">return</span> modified, deleted\n<span class="kw">end</span>`
  }
};

const flowSteps = [...document.querySelectorAll(".flow-step")];
const flowKicker = document.querySelector("[data-flow-kicker]");
const flowCode = document.querySelector("[data-flow-code]");
const flowTitle = document.querySelector("[data-flow-title]");
const flowCopy = document.querySelector("[data-flow-copy]");
const flowPoints = document.querySelector("[data-flow-points]");

function selectFlow(index) {
  const item = flowContent[index];
  flowSteps.forEach((step, i) => {
    const active = i === index;
    step.classList.toggle("is-active", active);
    step.setAttribute("aria-selected", String(active));
  });
  flowKicker.textContent = item.kicker;
  flowCode.textContent = item.code;
  flowTitle.textContent = item.title;
  flowCopy.textContent = item.copy;
  flowPoints.replaceChildren(...item.points.map((point) => {
    const li = document.createElement("li");
    li.textContent = point;
    return li;
  }));
}

flowSteps.forEach((step) => step.addEventListener("click", () => selectFlow(Number(step.dataset.step))));

const decisionTabs = [...document.querySelectorAll(".decision-tab")];
const decisionPanel = document.querySelector("[data-decision-panel]");
const decisionFile = decisionPanel.querySelector(".code-window-bar span");
const decisionCode = document.querySelector("[data-decision-code]");
const decisionTitle = document.querySelector("[data-decision-title]");
const decisionCopy = document.querySelector("[data-decision-copy]");

decisionTabs.forEach((tab) => {
  tab.addEventListener("click", () => {
    const item = decisions[tab.dataset.decision];
    decisionTabs.forEach((candidate) => {
      const active = candidate === tab;
      candidate.classList.toggle("is-active", active);
      candidate.setAttribute("aria-selected", String(active));
    });
    decisionFile.textContent = item.file;
    decisionCode.innerHTML = item.code;
    decisionTitle.textContent = item.title;
    decisionCopy.textContent = item.copy;
  });
});

const menuButton = document.querySelector(".menu-toggle");
const navigation = document.querySelector(".site-nav");
menuButton.addEventListener("click", () => {
  const open = navigation.classList.toggle("is-open");
  menuButton.setAttribute("aria-expanded", String(open));
});
navigation.querySelectorAll("a").forEach((link) => link.addEventListener("click", () => {
  navigation.classList.remove("is-open");
  menuButton.setAttribute("aria-expanded", "false");
}));

const navLinks = [...navigation.querySelectorAll("a")];
const navSections = navLinks.map((link) => document.querySelector(link.getAttribute("href"))).filter(Boolean);
const sectionObserver = new IntersectionObserver((entries) => {
  entries.forEach((entry) => {
    if (!entry.isIntersecting) return;
    navLinks.forEach((link) => link.classList.toggle("is-active", link.getAttribute("href") === `#${entry.target.id}`));
  });
}, { rootMargin: "-30% 0px -62%", threshold: 0 });
navSections.forEach((section) => sectionObserver.observe(section));

const barChart = document.querySelector("[data-bars]");
new IntersectionObserver((entries, observer) => {
  if (entries[0].isIntersecting) {
    barChart.classList.add("is-visible");
    observer.disconnect();
  }
}, { threshold: .25 }).observe(barChart);

const progress = document.querySelector(".reading-progress span");
function updateProgress() {
  const scrollable = document.documentElement.scrollHeight - window.innerHeight;
  const ratio = scrollable > 0 ? window.scrollY / scrollable : 0;
  progress.style.width = `${Math.min(100, Math.max(0, ratio * 100))}%`;
}
window.addEventListener("scroll", updateProgress, { passive: true });
updateProgress();

const copyButton = document.querySelector("[data-copy-pitch]");
copyButton.addEventListener("click", async () => {
  const text = document.querySelector("#pitch-text").textContent.replace(/^“|”$/g, "");
  try {
    await navigator.clipboard.writeText(text);
    copyButton.querySelector("span").textContent = "Copied";
    setTimeout(() => { copyButton.querySelector("span").textContent = "Copy pitch"; }, 1800);
  } catch {
    copyButton.querySelector("span").textContent = "Select + copy";
  }
});
