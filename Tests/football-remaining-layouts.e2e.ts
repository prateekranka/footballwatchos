import { test } from '@e2e-dev/mobile';
import { expect } from 'e2e';
import { fixture, layout, openFresh, tab, type FootballUI } from './support/football-ui.ts';

async function prepareLarge(ui: FootballUI) {
  await openFresh(ui);
  await ui.device.setAppearance('light');
  await fixture(ui, 'Demo data');
  await layout(ui, '200% text at 320 pt');
  await tab(ui.screen, 'Sessions').tap();
}

test('large text keeps Progress and sync usable', { timeout: 180_000 }, async ui => {
  const { app, screen } = ui;
  await prepareLarge(ui);
  await tab(screen, 'Progress').tap();
  await app.screenshot('large-progress-distance');
  await screen.getByRole('tab', 'Heart rate', { exact: true }).tap();
  await expect(screen.getByText('Average heart rate', { exact: true })).toBeVisible();
  await screen.getByRole('tab', 'All time', { exact: true }).tap();
  await app.screenshot('large-progress-heart-all-time');
  await screen.getByRole('scroll-view').first().swipe({ direction: 'down' });
  await app.screenshot('large-progress-lower');
  await tab(screen, 'Sessions').tap();
  await screen.getByRole('button', /^Sync status:/).tap();
  await app.screenshot('large-sync-top');
  await screen.getByRole('scroll-view').first().swipe({ direction: 'down' });
  await app.screenshot('large-sync-lower');
  await screen.getByRole('button', 'Done', { exact: true }).tap();
  await layout(ui, 'Standard');
  await tab(screen, 'Progress').tap();
  await screen.scrollUntilVisible(screen.getByRole('tab', 'Heart rate', { exact: true }), { direction: 'up' });
  await screen.getByRole('tab', 'Heart rate', { exact: true }).tap();
  await screen.getByRole('tab', 'All time', { exact: true }).tap();
  await app.screenshot('progress-heart-all-time');
  await layout(ui, 'Animations off');
  await tab(screen, 'Progress').tap();
  await screen.scrollUntilVisible(screen.getByRole('tab', 'Distance', { exact: true }), { direction: 'up' });
  await screen.getByRole('tab', 'Distance', { exact: true }).tap();
  await app.screenshot('progress-animations-off');
});

test('large text permits duration entry and persists the manual log', { timeout: 180_000 }, async ui => {
  const { app, screen } = ui;
  await prepareLarge(ui);
  await screen.getByTestId('add-session').tap();
  await app.screenshot('large-session-form-top');
  const duration = screen.getByTestId('session-duration');
  await screen.scrollUntilVisible(duration, { direction: 'down' });
  // Native Form can publish offscreen fields. Keep the complete input above
  // the keyboard before focusing it, using measured bounds and short swipes.
  for (let attempt = 0; attempt < 8; attempt++) {
    const box = await duration.boundingBox();
    console.log('Large duration bounds', box);
    if (box && box.y >= 170 && box.y + box.height <= 500) break;
    const scrollUp = box && box.y < 170;
    await screen.swipe({ from: { x: 201, y: scrollUp ? 220 : 420 }, to: { x: 201, y: scrollUp ? 420 : 220 }, duration: 800 });
  }
  await app.screenshot('large-duration-before-focus');
  await duration.tap();
  await expect(screen.getByRole('button', 'Done', { exact: true })).toBeVisible();
  await screen.getByTestId('session-duration').fill('90');
  await expect(screen.getByTestId('session-duration')).toHaveValue('90');
  await app.screenshot('large-session-form-keyboard');
  await ui.device.dismissKeyboard();
  await screen.getByRole('collection-view').swipe({ direction: 'down' });
  await app.screenshot('large-session-form-lower');
  await screen.getByTestId('save-session').tap();
  await expect(screen.getByTestId('add-session')).toBeVisible();
  await app.restart();
  await tab(screen, 'Settings').tap();
  await expect(screen.getByText('Sessions on this iPhone, 5', { exact: true })).toBeVisible();
  await app.screenshot('large-manual-log-persisted');
});

test('large text keeps all three onboarding pages and actions usable', { timeout: 180_000 }, async ui => {
  const { app, screen } = ui;
  await prepareLarge(ui);
  await tab(screen, 'Settings').tap();
  await screen.getByRole('collection-view').swipe({ direction: 'down' });
  const review = screen.getByRole('button', 'Review onboarding', { exact: true });
  await screen.scrollUntilVisible(review, { direction: 'down' });
  await review.tap();
  for (let page = 1; page <= 3; page++) {
    await expect(screen.getByTestId('onboarding-title')).toBeVisible();
    await app.screenshot(`large-onboarding-${page}-top`);
    await screen.getByRole('scroll-view').first().swipe({ direction: 'down' });
    await app.screenshot(`large-onboarding-${page}-lower`);
    await expect(screen.getByTestId('onboarding-continue')).toBeVisible();
    await screen.getByTestId('onboarding-continue').tap();
  }
});
