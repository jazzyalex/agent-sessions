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
    starContainer.style.display = "inline";
  } catch {
    // Star count is decorative; never block the page.
  }
}

loadGitHubStars();

for (const link of document.querySelectorAll("a.btn")) {
  link.addEventListener("click", () => {
    if (!window.goatcounter || typeof window.goatcounter.count !== "function") return;
    const destination = link.href.includes("/releases/") || link.textContent.includes("Download")
      ? "download"
      : link.href.includes("github.com") ? "github" : "product";
    const slug = window.location.pathname.split("/").filter(Boolean).pop()?.replace(/\.html$/, "") || "guides";
    window.goatcounter.count({
      path: `${destination}-guide-${slug}`,
      title: link.textContent.trim(),
      event: true
    });
  });
}
