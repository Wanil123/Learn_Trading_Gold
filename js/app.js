// Gold Trading Academy - App shared logic
// Progression tracking via localStorage

const TOTAL_MODULES = 14;

// === LANGUAGE TOGGLE ===
function getLang() {
  return document.documentElement.lang || 'fr';
}
function createLangToggle() {
  const lang = getLang();
  const btn = document.createElement('a');
  btn.className = 'lang-toggle';
  btn.title = lang === 'fr' ? 'Switch to English' : 'Passer en français';
  btn.textContent = lang === 'fr' ? '🇬🇧 EN' : '🇫🇷 FR';

  const loc = window.location;
  const path = loc.pathname;
  const proto = loc.protocol;

  if (proto === 'file:') {
    // Local file system: swap /en/ segment
    if (lang === 'fr') {
      const idx = path.lastIndexOf('/');
      const dir = path.substring(0, idx);
      const file = path.substring(idx);
      if (path.includes('/modules/') || path.includes('/tools/')) {
        const base = dir.substring(0, dir.lastIndexOf('/'));
        btn.href = base + '/en' + dir.substring(dir.lastIndexOf('/')) + file;
      } else {
        btn.href = dir + '/en' + file;
      }
    } else {
      btn.href = path.replace(/\/en\//, '/').replace(/\/en\//, '/');
    }
  } else {
    // Web server (Netlify etc): simple /en/ prefix toggle
    if (lang === 'fr') {
      if (path === '/' || path === '/index.html') {
        btn.href = '/en/index.html';
      } else {
        btn.href = '/en' + path;
      }
    } else {
      btn.href = path.replace(/^\/en\//, '/').replace(/^\/en$/, '/');
    }
  }
  document.body.appendChild(btn);
}

// Inject CSS for toggle button
function injectLangCSS() {
  const s = document.createElement('style');
  s.textContent = `
    .lang-toggle {
      position: fixed;
      bottom: 1.5rem;
      right: 1.5rem;
      background: #F59E0B;
      color: #0A0A0A;
      font-weight: 700;
      font-size: 0.85rem;
      padding: 0.5rem 0.9rem;
      border-radius: 2rem;
      text-decoration: none;
      z-index: 9999;
      box-shadow: 0 4px 15px rgba(245,158,11,0.4);
      transition: all 0.2s;
    }
    .lang-toggle:hover { background: #D97706; transform: scale(1.05); }
    @media (max-width: 640px) {
      .lang-toggle { bottom: 1rem; right: 1rem; font-size: 0.75rem; padding: 0.4rem 0.7rem; }
    }
  `;
  document.head.appendChild(s);
}
injectLangCSS();

function getCompleted() {
  try {
    return JSON.parse(localStorage.getItem('gta_completed') || '[]');
  } catch(e) { return []; }
}
function setCompleted(arr) {
  localStorage.setItem('gta_completed', JSON.stringify(arr));
}
function markModuleDone(n) {
  const c = getCompleted();
  if (!c.includes(n)) { c.push(n); setCompleted(c); }
}
function isModuleDone(n) {
  return getCompleted().includes(n);
}

// Update homepage progress
function updateHomepageProgress() {
  const done = getCompleted();
  const bar = document.getElementById('progressBar');
  const txt = document.getElementById('progressText');
  if (bar && txt) {
    const pct = (done.length / TOTAL_MODULES) * 100;
    bar.style.width = pct + '%';
    txt.textContent = done.length + ' / ' + TOTAL_MODULES + ' modules';
  }
  // Mark completed cards
  document.querySelectorAll('.module-card').forEach(card => {
    const n = parseInt(card.dataset.module);
    if (done.includes(n)) card.classList.add('completed');
  });
}

// Mark current module complete button (used in module pages)
function initMarkDone(moduleNum) {
  const btn = document.getElementById('markDoneBtn');
  if (!btn) return;
  const refresh = () => {
    if (isModuleDone(moduleNum)) {
      btn.textContent = '✓ Module complété';
      btn.classList.add('done');
    } else {
      btn.textContent = 'Marquer comme complété';
      btn.classList.remove('done');
    }
  };
  btn.addEventListener('click', () => {
    markModuleDone(moduleNum);
    refresh();
  });
  refresh();
}

// Quiz engine
function initQuiz(containerId, questions) {
  const container = document.getElementById(containerId);
  if (!container) return;
  let answered = {};

  questions.forEach((q, i) => {
    const qDiv = document.createElement('div');
    qDiv.className = 'question';
    qDiv.innerHTML = `<p>${i+1}. ${q.q}</p>`;
    q.options.forEach((opt, j) => {
      const label = document.createElement('label');
      label.textContent = opt;
      label.addEventListener('click', () => {
        if (answered[i] !== undefined) return;
        answered[i] = j;
        if (j === q.correct) label.classList.add('correct');
        else {
          label.classList.add('wrong');
          // Show correct answer
          const labels = qDiv.querySelectorAll('label');
          labels[q.correct].classList.add('correct');
        }
        const exp = qDiv.querySelector('.explanation');
        if (exp) exp.classList.add('show');
        updateScore();
      });
      qDiv.appendChild(label);
    });
    if (q.explain) {
      const exp = document.createElement('div');
      exp.className = 'explanation';
      exp.innerHTML = '<strong>Explication :</strong> ' + q.explain;
      qDiv.appendChild(exp);
    }
    container.appendChild(qDiv);
  });

  const scoreDiv = document.createElement('div');
  scoreDiv.className = 'score';
  container.appendChild(scoreDiv);

  function updateScore() {
    let correct = 0, total = Object.keys(answered).length;
    Object.entries(answered).forEach(([i, a]) => {
      if (a === questions[parseInt(i)].correct) correct++;
    });
    const lang = getLang();
    scoreDiv.textContent = `Score : ${correct} / ${questions.length}`;
    if (total === questions.length && correct === questions.length) {
      scoreDiv.textContent += lang === 'fr' ? '  🎉 Parfait !' : '  🎉 Perfect!';
    }
  }
}

// Init on load
document.addEventListener('DOMContentLoaded', () => {
  updateHomepageProgress();
  createLangToggle();
});
