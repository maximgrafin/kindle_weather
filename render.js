const path = require('path');
const { pathToFileURL } = require('url');
const puppeteer = require('puppeteer');

const VIEWPORT = {
  width: 1024,
  height: 758,
  deviceScaleFactor: 1,
};

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

    await page.screenshot({
      path: outputPath,
      type: 'png',
      clip: {
        x: 0,
        y: 0,
        width: VIEWPORT.width,
        height: VIEWPORT.height,
      },
    });

    console.log(`Successfully rendered ${VIEWPORT.width}x${VIEWPORT.height} image to ${outputPath}`);
  } finally {
    await browser.close();
  }
}

renderWeatherPng().catch((err) => {
  console.error('Failed to render weather.png:', err);
  process.exit(1);
});
