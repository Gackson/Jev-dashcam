export function validateExclusions(value) {
  if (!Array.isArray(value) || value.length > 100) throw new Error('最多添加 100 条窗口排除规则');
  const ids = new Set();
  return value.map(rule => {
    if (!rule || typeof rule !== 'object') throw new Error('无效的窗口排除规则');
    for (const key of ['id', 'app', 'bundleID', 'title', 'match']) {
      if (typeof rule[key] !== 'string' || rule[key].length > 2000) throw new Error('无效的窗口排除规则');
    }
    if (!rule.id || ids.has(rule.id) || !rule.app.trim() || !rule.title.trim() || !['exact', 'contains'].includes(rule.match)) throw new Error('请填写来源 App 和窗口标题');
    ids.add(rule.id);
    return Object.fromEntries(['id', 'app', 'bundleID', 'title', 'match'].map(key => [key, rule[key]]));
  });
}
export function isWindowExcluded(rules, window) {
  return rules.some(rule => (rule.bundleID ? rule.bundleID === window.bundleID : rule.app === window.app)
    && (rule.match === 'contains' ? String(window.title || '').includes(rule.title) : rule.title === window.title));
}
