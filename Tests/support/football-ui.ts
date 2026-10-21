import type { App, Locator, Screen } from 'e2e';
import type { Device } from '@e2e-dev/mobile';
import { expect } from 'e2e';

export type FootballUI = { app: App; screen: Screen; device: Device };
export const bundleID = 'com.prateekranka.footballperformance';

export const tabs = { Sessions: 'figure.run', Progress: 'chart.bar.xaxis', Settings: 'gearshape' };
export const tab = (screen: Screen, name: keyof typeof tabs) => screen.getByRole('tablist', 'Tab Bar', { exact: true }).getByTestId(tabs[name]).first();

export async function openFresh({ app, screen, device }: FootballUI) {
  if (process.env.FP_APP_PATH) await device.installApp();
  await device.openApp(bundleID, { relaunch: true });
  await expect(screen.getByTestId(/^(onboarding-continue|gearshape)$/).first()).toBeVisible({ timeout: 15_000 });
  for (let page = 0; page < 3 && await screen.getByTestId('onboarding-continue').isVisible(); page++) {
    await app.screenshot(`first-use-page-${page + 1}`);
    await screen.getByTestId('onboarding-continue').tap();
  }
  await expect(tab(screen, 'Settings')).toBeVisible();
}

export async function fixture(ui: FootballUI, name: 'Demo data' | 'Worst case' | 'Empty' | 'One' | '1,000 rows' | 'Degraded evidence') {
  const { screen } = ui;
  await tab(screen, 'Settings').tap();
  await screen.scrollUntilVisible(screen.getByTestId('qa-data-fixture'), { direction: 'up' });
  await expect(screen.getByText('Simulator QA · synthetic data', { exact: true })).toBeVisible();
  // An explicit change first makes Empty repeatable after manual entry.
  if (name === 'Empty') {
    await screen.getByTestId('qa-data-fixture').tap();
    await screen.getByRole('button', 'Demo data', { exact: true }).tap();
    await expect(screen.getByText('Sessions on this iPhone, 4', { exact: true })).toBeVisible();
  }
  await screen.getByTestId('qa-data-fixture').tap();
  await screen.getByRole('button', name, { exact: true }).tap();
  const count = { 'Demo data': 4, 'Worst case': 6, Empty: 0, One: 1, '1,000 rows': 1000, 'Degraded evidence': 6 }[name];
  const countText = count === 1000 ? /Sessions on this iPhone, 1,?000/ : `Sessions on this iPhone, ${count}`;
  await expect(screen.getByText(countText, { exact: true })).toBeVisible({ timeout: 120_000 });
  await tab(screen, 'Sessions').tap();
}

export async function layout(ui: FootballUI, name: string) {
  const { screen } = ui;
  await tab(screen, 'Settings').tap();
  await screen.scrollUntilVisible(screen.getByTestId('qa-layout-stress'), { direction: 'up' });
  await screen.getByTestId('qa-layout-stress').tap();
  await screen.getByRole('button', name, { exact: true }).tap();
  await expect(screen.getByTestId('qa-layout-stress')).toHaveText(new RegExp(name.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')));
}

export async function tapScrollControl(screen: Screen, content: Locator, control: Locator, anchor: Locator = control) {
  await content.scrollUntilVisible(anchor, { direction: 'down', timeout: 60_000 });
  let lastBounds;
  for (let attempt = 0; attempt < 8; attempt++) {
    let previous = await anchor.boundingBox();
    await expect.poll(async () => {
      const current = await anchor.boundingBox();
      const stable = current !== null && previous !== null &&
        Math.abs(current.x - previous.x) < 1 && Math.abs(current.y - previous.y) < 1 &&
        Math.abs(current.width - previous.width) < 1 && Math.abs(current.height - previous.height) < 1;
      previous = current;
      return stable;
    }, { timeout: 5_000, message: 'The scroll target must stop moving before a tap' }).toBe(true);
    const box = previous;
    const scroll = await content.boundingBox();
    const dock = await screen.getByRole('tablist', 'Tab Bar', { exact: true }).boundingBox();
    const button = await control.boundingBox();
    if (!box || !scroll || !dock || !button) throw new Error('A scroll tap needs target, button, scroll view, and tab bar bounds');
    const top = scroll.y + Math.max(16, scroll.height * 0.12);
    const bottom = Math.min(scroll.y + scroll.height, dock.y) - 16;
    const x = box.x + box.width / 2;
    const y = box.y + box.height / 2;
    lastBounds = { anchor: box, button, scroll, dock, top, bottom };
    if (box.width <= 0 || box.height <= 0 || bottom <= top) throw new Error(`No usable scroll tap area: ${JSON.stringify(lastBounds)}`);
    if (box.y >= top && box.y + box.height <= bottom) {
      expect(x).toBeGreaterThan(Math.max(scroll.x, button.x));
      expect(x).toBeLessThan(Math.min(scroll.x + scroll.width, button.x + button.width));
      expect(y).toBeGreaterThan(button.y);
      expect(y).toBeLessThan(button.y + button.height);
      await expect(control).toBeEnabled();
      await control.tap({ position: { x: x - button.x, y: y - button.y } });
      return;
    }
    const middle = (top + bottom) / 2;
    const limit = (bottom - top) * 0.4;
    const delta = Math.max(-limit, Math.min(limit, y - middle));
    await screen.swipe({
      from: { x: scroll.x + scroll.width / 2, y: middle + delta / 2 },
      to: { x: scroll.x + scroll.width / 2, y: middle - delta / 2 },
      duration: 500,
    });
  }
  throw new Error(`Control could not be scrolled clear of the floating tab bar: ${JSON.stringify(lastBounds)}`);
}

export async function openAddSession({ screen }: FootballUI) {
  const content = screen.getByRole('scroll-view').first();
  await content.scrollUntilVisible(screen.getByText(/^Good (morning|afternoon|evening)$/), { direction: 'up' });
  const add = screen.getByRole('button', 'Add session', { exact: true });
  await tapScrollControl(screen, content, add, add.getByText('Add session', { exact: true }));
  await expect(screen.getByTestId('save-session')).toBeVisible();
}

export async function addManual(ui: FootballUI, type: string, duration: string, label?: string) {
  const { app, screen } = ui;
  await openAddSession(ui);
  await screen.getByTestId('session-type').getByText(/^(Football|5-a-side|7-a-side|11-a-side|Training|Calibration)$/).tap();
  if (label) await app.screenshot(`${label}-type-menu`);
  await screen.getByRole('button', type, { exact: true }).tap();
  await expect(screen.getByRole('button', type, { exact: true })).toBeHidden();
  await screen.getByTestId('session-duration').tap();
  await expect(screen.getByRole('button', 'Done', { exact: true })).toBeVisible();
  await screen.getByTestId('session-duration').fill(duration);
  await expect(screen.getByTestId('session-duration')).toHaveValue(duration);
  await screen.getByRole('button', 'Done', { exact: true }).tap();
  if (label) await app.screenshot(`${label}-form`);
  await screen.getByTestId('save-session').tap();
  await expect(screen.getByTestId('save-session')).toBeHidden();
  await expect(tab(screen, 'Sessions')).toBeVisible();
  if (label) await app.screenshot(`${label}-saved`);
}

export async function latest(ui: FootballUI, sourceText: string) {
  const content = ui.screen.getByRole('scroll-view').first();
  const row = content.getByRole('button', new RegExp(sourceText)).first();
  const title = row.getByText(new RegExp(sourceText)).first();
  await tapScrollControl(ui.screen, content, row, title);
  await expect(ui.screen.getByTestId('session-hero')).toBeVisible();
}

export async function explore(ui: FootballUI, name: string) {
  const content = ui.screen.getByRole('scroll-view').first();
  await content.scrollUntilVisible(ui.screen.getByTestId('session-hero'), { direction: 'up', timeout: 60_000 });
  const row = content.getByRole('button', new RegExp(`^${name}`));
  await tapScrollControl(ui.screen, content, row, row.getByText(name, { exact: true }));
}

export async function dismissPopover(screen: Screen, content: Locator) {
  const dismiss = screen.getByTestId('PopoverDismissRegion');
  await expect(dismiss).toBeVisible();
  const region = await dismiss.boundingBox();
  const popup = await content.boundingBox();
  if (!region || !popup) throw new Error('Popover dismissal needs bounds for the dismiss region and its content');
  const below = popup.y + popup.height / 2 < region.y + region.height / 2;
  await dismiss.tap({ position: { x: region.width / 2, y: region.height * (below ? 0.85 : 0.15) } });
  await expect(dismiss).toBeHidden();
}
