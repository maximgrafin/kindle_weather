const fs = require('fs');
const path = require('path');
const { pathToFileURL } = require('url');
const puppeteer = require('puppeteer');

const VIEWPORT = {
  width: 1024,
  height: 758,
  deviceScaleFactor: 1,
};

const ROTATIONS = [
  { angle: 90, filename: 'weather-90.png' },
  { angle: 180, filename: 'weather-180.png' },
  { angle: 270, filename: 'weather-270.png' },
];

async function renderWeatherPng() {
  const templatePath = path.resolve(__dirname, 'template.html');
  const outputPath = path.resolve(__dirname, 'weather.png');
  const fileUrl = pathToFileURL(templatePath).href;

  console.log(`Opening template: ${fileUrl}`);

  const browser = await puppeteer.launch({
    headless: true,
    args: [
      '--no-sandbox',
      '--disable-setuid-sandbox',
      '--disable-dev-shm-usage',
      '--font-render-hinting=medium',
    ],
  });

  try {
    const page = await browser.newPage();
    await page.setViewport(VIEWPORT);
    await page.emulateTimezone('Europe/Berlin');

    page.on('pageerror', (err) => {
      console.error('Page runtime error:', err);
    });

    await page.goto(fileUrl, {
      waitUntil: 'networkidle0',
      timeout: 30000,
    });

    // Wait until Open-Meteo data is fetched and rendered into DOM (or error is reported)
    await page.waitForFunction(
      () => window.__WEATHER_READY__ === true || Boolean(window.__WEATHER_ERROR__),
      { timeout: 20000 }
    );

    const weatherError = await page.evaluate(() => window.__WEATHER_ERROR__);
    if (weatherError) {
      throw new Error(`Weather API/render error in template.html: ${weatherError}`);
    }

    // Ensure Google Fonts have finished loading before taking the screenshot
    await page.evaluate(() => document.fonts.ready);

    const baseBuffer = await page.screenshot({
      path: outputPath,
      type: 'png',
      clip: {
        x: 0,
        y: 0,
        width: VIEWPORT.width,
        height: VIEWPORT.height,
      },
    });

    console.log(`Successfully rendered ${VIEWPORT.width}x${VIEWPORT.height} (0°) to ${outputPath}`);

    // Losslessly rotate the 0° screenshot by 90°, 180°, and 270° clockwise using integer transforms
    const baseDataUrl = `data:image/png;base64,${Buffer.from(baseBuffer).toString('base64')}`;
    const rotatedResults = await page.evaluate(
      async (srcDataUrl, w, h, rotations) => {
        const img = new Image();
        img.src = srcDataUrl;
        await img.decode();

        return rotations.map(({ angle, filename }) => {
          const canvas = document.createElement('canvas');
          if (angle === 90 || angle === 270) {
            canvas.width = h;
            canvas.height = w;
          } else {
            canvas.width = w;
            canvas.height = h;
          }

          const ctx = canvas.getContext('2d');
          ctx.imageSmoothingEnabled = false;

          if (angle === 90) {
            ctx.setTransform(0, 1, -1, 0, h, 0);
          } else if (angle === 180) {
            ctx.setTransform(-1, 0, 0, -1, w, h);
          } else if (angle === 270) {
            ctx.setTransform(0, -1, 1, 0, 0, w);
          }

          ctx.drawImage(img, 0, 0);
          const dataUrl = canvas.toDataURL('image/png');
          return {
            angle,
            filename,
            width: canvas.width,
            height: canvas.height,
            base64: dataUrl.replace(/^data:image\/png;base64,/, ''),
          };
        });
      },
      baseDataUrl,
      VIEWPORT.width,
      VIEWPORT.height,
      ROTATIONS
    );

    for (const item of rotatedResults) {
      const destPath = path.resolve(__dirname, item.filename);
      fs.writeFileSync(destPath, Buffer.from(item.base64, 'base64'));
      console.log(`Successfully rendered ${item.width}x${item.height} (${item.angle}°) to ${destPath}`);
    }
  } finally {
    await browser.close();
  }
}

renderWeatherPng().catch((err) => {
  console.error('Failed to render weather images:', err);
  process.exit(1);
});
