import { chromium } from "playwright";

const browser = await chromium.launch();
try {
  const page = await browser.newPage();
  await page.setContent('<button id="check">run</button><output id="result"></output>');
  await page.evaluate(() => {
    document.querySelector("#check").onclick = () => {
      document.querySelector("#result").textContent = "browser-ok";
    };
  });
  await page.click("#check");
  const value = await page.locator("#result").textContent();
  if (value !== "browser-ok") {
    throw new Error(`Unexpected browser result: ${value}`);
  }
  console.log(value);
} finally {
  await browser.close();
}
