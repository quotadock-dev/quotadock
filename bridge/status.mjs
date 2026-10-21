// Text presentation of the already-sanitized v1 snapshot; no collection or storage.
export function formatStatus(snapshot, { language = 'en', now = Date.now() } = {}) {
  const text = (en, ko) => language === 'ko' ? ko : en;
  const unknown = text('Unknown', '알 수 없음');
  const number = new Intl.NumberFormat(language === 'ko' ? 'ko-KR' : 'en-US', { maximumFractionDigits: 2 });
  const windowNames = { Session: '세션', Weekly: '주간', Monthly: '월간', Daily: '일간', Credits: '크레딧', Additional: '추가', Secondary: '보조', '5-hour': '5시간', '7-day': '7일', 'Pro tier': 'Pro 등급', 'Flash tier': 'Flash 등급', 'Flash Lite tier': 'Flash Lite 등급' };
  const lines = [
    `Allowmark · ${snapshot.demo ? text('DEMO · SAMPLE DATA', 'DEMO · 예시 데이터') : text('LOCAL CHECK', '로컬 확인')}`,
    `${text('Snapshot generated (not source observation)', '스냅샷 생성 (원본 관측 시각 아님)')}: ${snapshot.generatedAt}`,
  ];
  for (const provider of snapshot.providers) {
    lines.push('', `${provider.name} · ${text('Plan', '요금제')}: ${provider.plan ?? unknown}`);
    const observed = provider.observedAt;
    const age = observed === null ? null : now - Date.parse(observed);
    const freshness = age === null ? text('UNKNOWN TIME', '시각 알 수 없음')
      : age < 0 ? text('FUTURE TIMESTAMP', '미래 시각')
      : age > 15 * 60000 ? text('STALE', '오래된 관측') : text('RECENT OBSERVATION', '최근 관측');
    lines.push(`  ${text('Observed', '관측')}: ${observed ?? unknown} · ${freshness}`);
    if (provider.state !== 'available') lines.push(`  ${text('Measured quota unavailable; check CodexBar locally.', '실제 할당량 확인 불가 · 로컬 CodexBar를 확인하세요.')}`);
    for (const window of provider.windows) {
      const remaining = window.remainingPercent;
      // Only measured zero gets an empty bar, even below one character's width.
      const filled = remaining === null ? null : remaining === 0 ? 0 : Math.max(1, Math.floor(remaining * 30 / 100));
      const bar = filled === null ? '?'.repeat(30) : '#'.repeat(filled) + '-'.repeat(30 - filled);
      const label = language === 'ko' ? windowNames[window.label] ?? window.label : window.label;
      const amount = remaining === null ? unknown
        : remaining > 0 && remaining < 0.01 ? text('Less than 0.01%', '0.01% 미만')
        : remaining > 99.99 && remaining < 100 ? text('More than 99.99%', '99.99% 초과') : `${number.format(remaining)}%`;
      lines.push(`  ${label} [${bar}] ${amount}${remaining === null ? '' : ` ${text('remaining', '남음')}`}`);
      lines.push(`    ${text('Reset', '리셋')}: ${window.resetsAt ?? unknown}`);
    }
  }
  lines.push('', text(
    'Times are UTC. Windows are independent; never add them. A reset time does not refill a reading. Codex is not total ChatGPT usage.',
    '시각은 UTC입니다. 각 구간은 독립적이며 합산하지 않습니다. 리셋 시각이 지나도 관측값을 채우지 않습니다. Codex는 ChatGPT 전체 사용량이 아닙니다.',
  ));
  return lines.join('\n') + '\n';
}
