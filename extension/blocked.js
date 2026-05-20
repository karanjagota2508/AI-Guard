const params = new URLSearchParams(window.location.search);
document.getElementById("target").textContent = params.get("target") || "unknown target";
