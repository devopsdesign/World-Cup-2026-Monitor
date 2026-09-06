# Present at the repo root so pytest puts the repo root on sys.path,
# regardless of how it's invoked — that's what makes `import src.app.main`
# resolve from tests/. No fixtures needed yet.
