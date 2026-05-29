const year = document.getElementById("year");
if (year) {
  year.textContent = new Date().getFullYear();
}

async function loadGitHubStars() {
  const starCount = document.getElementById("github-stars");
  const starContainer = document.getElementById("github-stars-container");
  if (!starCount || !starContainer) return;

  try {
    const response = await fetch("https://api.github.com/repos/jazzyalex/agent-sessions", {
      headers: { Accept: "application/vnd.github+json" }
    });
    if (!response.ok) return;
    const repo = await response.json();
    starCount.textContent = repo.stargazers_count ?? 0;
    starContainer.hidden = false;
  } catch {
    // Star count is decorative; never block the page.
  }
}

loadGitHubStars();
