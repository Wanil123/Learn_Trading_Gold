// Gold Trading Academy - App shared logic
// Progression tracking via localStorage

const TOTAL_MODULES = 14;

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
    scoreDiv.textContent = `Score : ${correct} / ${questions.length}`;
    if (total === questions.length && correct === questions.length) {
      scoreDiv.textContent += '  🎉 Parfait !';
    }
  }
}

// Init on load
document.addEventListener('DOMContentLoaded', updateHomepageProgress);
