document.addEventListener('DOMContentLoaded', () => {
  document.querySelectorAll('form').forEach(form => {
    form.addEventListener('submit', () => {
      const btn = form.querySelector('button[type="submit"]');
      if (btn) { 
        btn.disabled = true; 
        btn.textContent = 'Processing...'; 
      }
    });
  });

  const fileInput = document.querySelector('input[type="file"]');
  if (fileInput) {
    fileInput.addEventListener('change', (e) => {
      const f = e.target.files[0];
      if (!f) return;
      const mb = (f.size / 1024 / 1024).toFixed(2);
      console.log(`Selected: ${f.name} (${mb} MB)`);
      if (mb > 500) {
        alert('File size exceeds 500MB limit!');
        e.target.value = '';
      }
    });
  }
});
