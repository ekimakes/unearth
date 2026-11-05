# Unearth's website

One static page: `index.html`, with its CSS and JavaScript inside it, and the pictures in `assets/`. There's no build step, no cookies, no analytics, no third-party scripts and no web fonts. Any static host can serve this folder as it is.

## Preview it

```bash
python3 -m http.server 4173 --directory website
```

Then open http://localhost:4173.

## Where the download number comes from

The number next to the button is GitHub's own count. On load, the page asks `https://api.github.com/repos/ekimakes/unearth/releases?per_page=100` and adds up `download_count` for every file of every release.

- It counts downloads, not unique people. One person downloading twice counts twice.
- GitHub allows 60 of these requests an hour per visitor, so the page keeps the answer in `localStorage` for 10 minutes.
- If GitHub can't be reached, the page shows the last number that visitor saw. With nothing saved, it shows the button alone. It never shows a made-up number.
- At zero it says "Be the first to download".
- Until the repository and a first release exist, GitHub answers 404: the number stays hidden, and the console logs that 404.

## What to change

- **The repository or the file name:** the `RELEASE` const at the top of the script in `index.html`. Every release must attach a file with exactly that name, because the button links to `releases/latest/download/<file>`. The `href` values written in the HTML are only for visitors without JavaScript.
- **The site's address:** the `og:image` meta tag needs a full URL. It assumes GitHub Pages at `ekimakes.github.io/unearth`.
- **The strata at the top:** `LAYERS`, `USED` and `SAFE` in the script. They match the sample Mac in the screenshots, as do the size labels above each section's heading.

## The pictures

Every screen in `assets/` is the real app, rendered from a made-up sample Mac: generated pictures, fake invoices and four sample apps. None of it is anyone's real files. Their sizes and Library counts were scaled up so the sample reads as a normal 1 TB Mac, which is why the footer says the screens show a sample Mac.
