import { test } from '@e2e-dev/mobile';
import { expect } from 'e2e';
import { addManual, fixture, latest, openFresh, tab, tapScrollControl } from './support/football-ui.ts';

test('onboarding keeps all guidance reachable and opens each step at its title', async ui => {
  const { app, screen } = ui;
  await openFresh(ui);
  await fixture(ui, 'Empty');
  await tab(screen, 'Settings').tap();
  const review = screen.getByRole('button', 'Review onboarding', { exact: true });
  await screen.getByRole('collection-view').swipe({ direction: 'down' });
  await screen.scrollUntilVisible(review, { direction: 'down' });
  await app.screenshot('settings-lower');
  await review.tap();
  await app.screenshot('onboarding-welcome');
  await expect(screen.getByTestId('onboarding-title')).toHaveText('Your football sessions');
  await screen.getByTestId('onboarding-continue').tap();
  await app.screenshot('onboarding-two-ways-top');
  await screen.scrollUntilVisible(screen.getByText('Log on iPhone', { exact: true }), { direction: 'down' });
  await app.screenshot('onboarding-two-ways-lower');
  await screen.getByTestId('onboarding-continue').tap();
  await app.screenshot('onboarding-evidence-after-scroll');
  await expect(screen.getByTestId('onboarding-title')).toBeVisible();
  await screen.scrollUntilVisible(screen.getByText('Your data, clearly labelled', { exact: true }), { direction: 'down' });
  await app.screenshot('onboarding-evidence-lower');
  await screen.getByTestId('onboarding-back').tap();
  await expect(screen.getByTestId('onboarding-title')).toHaveText('Two ways to save');
  await screen.getByTestId('onboarding-continue').tap();
  await screen.getByTestId('onboarding-continue').tap();
  await tab(screen, 'Sessions').tap();
  await expect(screen.getByText('No sessions yet', { exact: true })).toBeVisible();
  await app.screenshot('sessions-empty');
});

test('duration validation rejects invalid input and Cancel leaves no session', async ui => {
  const { app, screen } = ui;
  await openFresh(ui);
  await fixture(ui, 'Empty');
  await screen.getByTestId('add-session').tap();
  await app.screenshot('add-session-default');
  for (const [index, value] of ['', '0', '-1', '241', '1.5', 'ball'].entries()) {
    await screen.scrollUntilVisible(screen.getByTestId('session-duration'), { direction: 'up' });
    await screen.getByTestId('session-duration').tap();
    await expect(screen.getByRole('button', 'Done', { exact: true })).toBeVisible();
    await screen.getByTestId('session-duration').fill(value);
    // UIKit exposes the placeholder as the AX value of an empty field.
    if (value !== '') await expect(screen.getByTestId('session-duration')).toHaveValue(value);
    if (index === 1) await app.screenshot('add-session-keyboard');
    await screen.getByTestId('save-session').tap();
    await screen.scrollUntilVisible(screen.getByTestId('session-validation').first(), { direction: 'down' });
    await expect(screen.getByTestId('session-validation').first()).toBeVisible();
    await expect(screen.getByText('Enter a whole number from 1 to 240 minutes.', { exact: true })).toBeVisible();
    await app.screenshot(`add-session-invalid-${index}`);
  }
  await screen.getByRole('button', 'Cancel', { exact: true }).tap();
  await expect(screen.getByText('No sessions yet', { exact: true })).toBeVisible();
});

test('all six football types and durations persist as manual logs', { timeout: 360_000 }, async ui => {
  const { app, screen } = ui;
  await openFresh(ui);
  await fixture(ui, 'Empty');
  const sessions = [['Football', '1'], ['5-a-side', '15'], ['7-a-side', '45'], ['11-a-side', '60'], ['Training', '90'], ['Calibration', '240']];
  for (const [index, [type, minutes]] of sessions.entries()) {
    await addManual(ui, type, minutes, `manual-${index + 1}-${minutes}min`);
    await latest(ui, `${type}.*Manual log`);
    await expect(screen.getByTestId('session-hero').getByText(`${type} · Manual log`, { exact: true })).toBeVisible();
    await expect(screen.getByTestId('session-hero-duration')).toHaveText(`${minutes} min, Duration`);
    await app.back();
  }
  await app.restart();
  await tab(screen, 'Settings').tap();
  await expect(screen.getByText('Sessions on this iPhone, 6', { exact: true })).toBeVisible();
  await app.screenshot('settings-six-manual-logs');
  await tab(screen, 'Sessions').tap();
  await screen.getByRole('scroll-view').first().scrollUntilVisible(screen.getByRole('button', /^Sync status:/), { direction: 'up' });
  await expect(screen.getByText('Manual logs saved on iPhone', { exact: true })).toBeVisible();
  await tapScrollControl(screen, screen.getByRole('scroll-view').first(), screen.getByRole('button', 'See all', { exact: true }));
  await app.screenshot('all-manual-sessions-top');
  const football = screen.getByRole('button', /Football · Manual log/);
  await screen.getByRole('scroll-view').first().scrollUntilVisible(football, { direction: 'down' });
  await app.screenshot('all-manual-sessions-bottom');
  await expect(football.getByText('1 min', { exact: true })).toBeVisible();
  await tab(screen, 'Progress').tap();
  const noCoverage = screen.getByText('Not enough sensor coverage', { exact: true });
  await screen.getByRole('scroll-view').first().scrollUntilVisible(noCoverage, { direction: 'down', timeout: 60_000 });
  await expect(noCoverage).toBeVisible();
  await expect(screen.getByText('Comparisons need whole-session coverage. Sparse HR, distance gaps, and interrupted recordings stay out of trends.', { exact: true })).toBeVisible();
  await app.screenshot('progress-manual-only');
});
