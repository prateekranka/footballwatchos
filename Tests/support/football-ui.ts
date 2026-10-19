import type { App, Screen } from 'e2e';
import type { Device } from '@e2e-dev/mobile';
import { expect } from 'e2e';

export type FootballUI = { app: App; screen: Screen; device: Device };
export const bundleID = 'com.prateekranka.footballperformance';

export const tabs = { Sessions: 'figure.run', Progress: 'chart.bar.xaxis', Settings: 'gearshape' };
export const tab = (screen: Screen, name: keyof typeof tabs) => screen.getByTestId(tabs[name]).first();

export async function openFresh({ app, screen, device }: FootballUI) {
  if (process.env.FP_APP_PATH) await device.installApp();
  await device.openApp(bundleID, { relaunch: true });
  await expect(screen.getByTestId(/^(onboarding-continue|add-session)$/)).toBeVisible({ timeout: 15_000 });
  for (let page = 0; page < 3 && await screen.getByTestId('onboarding-continue').isVisible(); page++) {
    await app.screenshot(`first-use-page-${page + 1}`);
    await screen.getByTestId('onboarding-continue').tap();
  }
  await expect(tab(screen, 'Settings')).toBeVisible();
}

export async function fixture(ui: FootballUI, name: 'Demo data' | 'Worst case' | 'Empty' | 'One' | '1,000 rows') {
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
  const count = { 'Demo data': 4, 'Worst case': 6, Empty: 0, One: 1, '1,000 rows': 1000 }[name];
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

export async function addManual(ui: FootballUI, type: string, duration: string, label?: string) {
  const { app, screen } = ui;
  await screen.scrollUntilVisible(screen.getByTestId('add-session'), { direction: 'up' });
  await screen.getByTestId('add-session').tap();
  await screen.getByTestId('session-type').getByText(/^(Football|5-a-side|7-a-side|11-a-side|Training|Calibration)$/).tap();
  if (label) await app.screenshot(`${label}-type-menu`);
  await screen.getByRole('button', type, { exact: true }).tap();
  await expect(screen.getByRole('button', type, { exact: true })).toBeHidden();
  await screen.getByTestId('session-duration').tap();
  await expect(screen.getByRole('button', 'Done', { exact: true })).toBeVisible();
  await screen.getByTestId('session-duration').fill(duration);
  await expect(screen.getByTestId('session-duration')).toHaveValue(duration);
  await ui.device.dismissKeyboard();
  if (label) await app.screenshot(`${label}-form`);
  await screen.getByTestId('save-session').tap();
  await expect(screen.getByTestId('add-session')).toBeVisible();
  if (label) await app.screenshot(`${label}-saved`);
}

export async function latest(ui: FootballUI, sourceText: string) {
  const card = ui.screen.getByRole('button', new RegExp(sourceText)).first();
  await ui.screen.scrollUntilVisible(card, { direction: 'up' });
  await card.tap();
}

export async function explore(ui: FootballUI, name: string) {
  const row = ui.screen.getByRole('button', new RegExp(`^${name}`));
  if (name === 'Details' || !await row.isVisible()) await ui.screen.getByRole('scroll-view').first().swipe({ direction: 'down' });
  await ui.screen.scrollUntilVisible(row, { direction: 'down' });
  await row.tap();
}
