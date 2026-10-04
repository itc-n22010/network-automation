(() => {
  'use strict';

  const logPicker = document.getElementById('logInput');
  const logName = document.getElementById('logName');
  const resultList = document.getElementById('items');
  const summary = document.getElementById('summary');
  const storagePrefix = 'network-console-check-v2:';
  const errorPattern = /(?:%\s*(?:invalid input|incomplete command|ambiguous command|error)|invalid input detected|command rejected)/i;
  const sectionPattern = /^(?:interface\s+|router\s+|line\s+|vlan\s+|ip\s+access-list\s+|policy-map\s+|class-map\s+|control-plane\b|vrf\s+definition\s+)/i;

  let logGroups = [];
  let records = [];
  let deviceRows = [];
  let deviceHeaders = [];
  let testRules = [];
  let configurationMessage = '';

  function cleanText(value) {
    return String(value || '')
      .replace(/\x1b\[[0-?]*[ -/]*[@-~]/g, '')
      .replace(/\x00/g, '')
      .replace(/\r/g, '');
  }

  function normalize(value) {
    return String(value || '').trim().replace(/\s+/g, ' ').toLocaleLowerCase();
  }

  function splitRules(value) {
    return String(value || '').split(/\r?\n/).map(line => line.trim()).filter(Boolean);
  }

  function parseCsv(text) {
    const rows = [];
    let row = [];
    let cell = '';
    let quoted = false;
    const source = String(text || '').replace(/^\uFEFF/, '').replace(/\r\n?/g, '\n');

    for (let index = 0; index < source.length; index += 1) {
      const character = source[index];
      if (quoted) {
        if (character === '"' && source[index + 1] === '"') {
          cell += '"';
          index += 1;
        } else if (character === '"') {
          quoted = false;
        } else {
          cell += character;
        }
      } else if (character === '"' && !cell) {
        quoted = true;
      } else if (character === ',') {
        row.push(cell);
        cell = '';
      } else if (character === '\n') {
        row.push(cell);
        if (row.some(value => value.trim())) rows.push(row);
        row = [];
        cell = '';
      } else {
        cell += character;
      }
    }
    row.push(cell);
    if (row.some(value => value.trim())) rows.push(row);
    if (quoted) throw new Error('CSVの引用符が閉じられていません。');
    if (rows.length < 2) throw new Error('CSVにヘッダーと機器データ行が必要です。');

    const headers = rows[0].map(value => value.trim());
    if (headers.some(value => !value) || new Set(headers.map(normalize)).size !== headers.length) {
      throw new Error('CSVのヘッダーが空、または重複しています。');
    }
    return {
      headers,
      rows: rows.slice(1).map(values => Object.fromEntries(headers.map((header, index) => [header, (values[index] || '').trim()])))
    };
  }

  function csvCell(row, headers, name) {
    const header = headers.find(value => normalize(value) === normalize(name));
    return header ? String(row?.[header] || '').trim() : '';
  }

  function csvValue(row, name) {
    return csvCell(row, deviceHeaders, name);
  }

  function parseTestRules(parsed) {
    if (!parsed.headers.some(header => normalize(header) === 'commandpattern')) {
      throw new Error('条件CSVに CommandPattern 列がありません。');
    }
    const rules = parsed.rows.map((row, index) => {
      const pattern = csvCell(row, parsed.headers, 'CommandPattern');
      if (!pattern) return null;
      const type = (csvCell(row, parsed.headers, 'Type') || 'auto').toLocaleLowerCase();
      if (!['auto', 'text', 'config', 'serial', 'setup'].includes(type)) {
        throw new Error(`${index + 2}行目のTypeは auto/text/config/serial/setup で指定してください。`);
      }
      let matcher;
      try {
        matcher = new RegExp(pattern, 'i');
      } catch {
        throw new Error(`${index + 2}行目のCommandPatternが正規表現として不正です。`);
      }
      return {
        matcher,
        type,
        required: csvCell(row, parsed.headers, 'Required'),
        forbidden: csvCell(row, parsed.headers, 'Forbidden')
      };
    }).filter(Boolean);
    if (!rules.length) throw new Error('条件CSVにCommandPatternの設定行がありません。');
    return rules;
  }

  function ruleForCommand(command) {
    return testRules.find(rule => rule.matcher.test(command)) || null;
  }

  async function loadCsv(path) {
    const response = await fetch(new URL(path, window.location.href), { cache: 'no-store' });
    if (!response.ok) throw new Error(`${path} (${response.status})`);
    return parseCsv(await response.text());
  }

  async function loadDefaultCsvFiles() {
    const failures = [];
    const [rulesResult, devicesResult] = await Promise.allSettled([
      loadCsv('test-rules.csv').then(parsed => { testRules = parseTestRules(parsed); }),
      loadCsv('../../CiscoAutoConfig/config/devices.csv').then(parsed => {
        deviceHeaders = parsed.headers.filter(header => !/(?:password|secret|credential|token|username)/i.test(header));
        deviceRows = parsed.rows.map(row => Object.fromEntries(deviceHeaders.map(header => [header, row[header]])));
      })
    ]);
    if (rulesResult.status === 'rejected') failures.push(`test-rules.csv: ${rulesResult.reason.message}`);
    if (devicesResult.status === 'rejected') failures.push(`CiscoAutoConfig/config/devices.csv: ${devicesResult.reason.message}`);
    configurationMessage = failures.join(' / ');
    updateRecords();
  }

  function deviceForGroup(group) {
    if (!deviceRows.length) return { row: null, reason: 'CSV未読込' };
    const observedSerials = logGroups
      .filter(candidate => normalize(candidate.folder) === normalize(group.folder))
      .flatMap(candidate => candidate.records
        .filter(record => ruleKind(record) === 'serial')
        .flatMap(record => extractSerials(record.output).map(item => item.value.toLocaleUpperCase())));
    const serialMatches = [...new Set(observedSerials)].flatMap(serial =>
      deviceRows.filter(row => csvValue(row, 'SerialNumber').toLocaleUpperCase() === serial));
    const uniqueSerialMatches = [...new Set(serialMatches)];
    if (uniqueSerialMatches.length === 1) return { row: uniqueSerialMatches[0], reason: '' };
    if (uniqueSerialMatches.length > 1) return { row: null, reason: 'CSV内でシリアルが重複' };
    if (observedSerials.length) return { row: null, reason: 'シリアルがCSVに未登録' };

    const folder = normalize(group.folder);
    const folderMatches = deviceRows.filter(row => ['Hostname', 'DeviceID'].some(field => normalize(csvValue(row, field)) === folder));
    const uniqueFolderMatches = [...new Set(folderMatches)];
    if (uniqueFolderMatches.length === 1) return { row: uniqueFolderMatches[0], reason: '' };
    if (uniqueFolderMatches.length > 1) return { row: null, reason: 'フォルダー名に一致するCSV行が複数' };
    return { row: null, reason: 'シリアル/フォルダー名がCSVに未登録' };
  }

  function expandCsvValues(value, group) {
    let error = '';
    const expanded = String(value || '').replace(/\$\{([^}]+)\}/g, (token, column) => {
      const match = deviceForGroup(group);
      if (!deviceRows.length) {
        error = 'CSVを読み込み、機器行を特定してください。';
        return token;
      }
      if (!match.row) {
        error = `CSVの機器行を特定できません（${match.reason}）。`;
        return token;
      }
      const replacement = csvValue(match.row, column);
      if (!replacement) {
        error = `CSV列「${column}」がないか、値が空です。`;
        return token;
      }
      return replacement;
    });
    return { value: expanded, error };
  }

  function readFile(file) {
    return new Promise((resolve, reject) => {
      const reader = new FileReader();
      reader.onload = () => resolve(String(reader.result || ''));
      reader.onerror = () => reject(reader.error || new Error('ファイルを読み込めません。'));
      reader.readAsText(file, 'UTF-8');
    });
  }

  function promptCommand(line) {
    const match = cleanText(line).match(/^\s*([A-Za-z0-9_.:-]+(?:\([^)]*\))?[>#])\s*(.*?)\s*$/);
    return match ? { prompt: match[1], command: match[2] } : null;
  }

  function splitLog(text) {
    const lines = cleanText(text).split('\n');
    const ignored = /^(?:enable|disable|exit|logout|end)$/i;
    const starts = lines.map((line, index) => {
      const parsed = promptCommand(line);
      if (!parsed || !parsed.command || ignored.test(parsed.command.trim())) return null;
      return { index, command: parsed.command.trim() };
    }).filter(Boolean);

    return starts.map((entry, index) => {
      const nextStart = starts[index + 1]?.index;
      const end = nextStart === undefined ? lines.length : nextStart;
      const outputLines = lines.slice(entry.index + 1, end);
      let complete = nextStart !== undefined;

      while (outputLines.length && !outputLines[outputLines.length - 1].trim()) outputLines.pop();
      if (outputLines.length && /^\s*[A-Za-z0-9_.:-]+(?:\([^)]*\))?[>#]\s*$/.test(outputLines[outputLines.length - 1])) {
        outputLines.pop();
        complete = true;
      }

      return { command: entry.command, found: true, complete, output: outputLines.join('\n').trim() };
    });
  }

  function extractSerials(text) {
    const labels = /^\s*(System\s+serial(?:\s+number)?|Processor\s+board\s+ID|Chassis\s+serial(?:\s+number)?|Serial\s+number)\s*:?\s*([A-Z0-9][A-Z0-9-]{3,})/i;
    const result = [];

    for (const line of cleanText(text).split('\n')) {
      const match = line.match(labels);
      if (!match) continue;
      const value = match[2].replace(/[.,;]+$/, '');
      const duplicate = result.find(item => item.value.toLocaleUpperCase() === value.toLocaleUpperCase());
      if (duplicate) {
        if (!duplicate.label.toLocaleLowerCase().includes(match[1].toLocaleLowerCase())) {
          duplicate.label += ` / ${match[1].trim()}`;
        }
        continue;
      }
      result.push({ label: match[1].trim(), value });
    }
    return result;
  }

  function configLines(text) {
    const lines = cleanText(text).split('\n');
    let start = lines.findIndex(line => /^\s*Current configuration\s*:/i.test(line));
    if (start < 0) start = lines.findIndex(line => /^\s*Building configuration\.\.\./i.test(line));
    if (start >= 0) start += 1;
    else start = 0;

    const result = [];
    for (const raw of lines.slice(start)) {
      const value = raw.trim();
      if (!value || value === '!') continue;
      if (/^end\s*$/i.test(value)) break;
      if (/^\S+[>#]\s*$/.test(value)) break;
      result.push(raw);
    }
    return result;
  }

  function configEntries(lines, omitSectionHeaders) {
    const entries = [];
    let section = '';

    for (const raw of lines) {
      const value = raw.trim();
      if (!value || value.startsWith('#')) continue;
      if (value === '!') {
        section = '';
        continue;
      }
      const indented = /^\s/.test(raw);
      const isSection = !indented && sectionPattern.test(value);
      if (!indented) section = isSection ? normalize(value) : '';
      if (isSection && omitSectionHeaders) continue;
      entries.push({ value: normalize(value), scope: section || '*', original: value });
    }
    return entries;
  }

  function makeField(labelText, field, ruleKey, initialValue, hint) {
    const wrapper = document.createElement('div');
    wrapper.className = 'rule';
    const label = document.createElement('label');
    label.textContent = labelText;
    const control = field === 'input' ? document.createElement('input') : document.createElement('textarea');
    control.dataset.rule = ruleKey;
    control.autocomplete = 'off';
    control.spellcheck = false;
    control.value = initialValue;
    const help = document.createElement('span');
    help.className = 'rule-hint';
    help.textContent = hint;
    wrapper.append(label, control, help);
    return wrapper;
  }

  function ruleKind(record) {
    const command = typeof record === 'string' ? record : record.command;
    const configured = ruleForCommand(command);
    if (configured && configured.type !== 'auto') return configured.type;
    const normalized = normalize(command);
    if (/^show\s+version\b/.test(normalized)) return 'serial';
    if (/^show\s+(?:running-config|run)\b/.test(normalized)) return 'config';
    if (/^(?:terminal\s+length\s+0|terminal\s+pager\s+0)$/.test(normalized)) return 'setup';
    return 'text';
  }

  function storageKey(groupKey) {
    return storagePrefix + groupKey;
  }

  function readProfile(groupKey) {
    try {
      return JSON.parse(localStorage.getItem(storageKey(groupKey)) || '{}');
    } catch {
      return {};
    }
  }

  function saveProfile() {
    const card = document.activeElement?.closest('.item');
    if (!card) return;
    const profile = readProfile(card.dataset.profileKey);
    const values = profile[card.dataset.profileRecordKey] || {};
    card.querySelectorAll('[data-rule]').forEach(control => {
      values[control.dataset.rule] = control.value;
    });
    profile[card.dataset.profileRecordKey] = values;
    try {
      localStorage.setItem(storageKey(card.dataset.profileKey), JSON.stringify(profile));
    } catch {
      document.getElementById('summaryDetail').textContent = '期待値をブラウザーに保存できません。現在のページを閉じる前に判定してください。';
    }
  }

  function addRules(card, record, profile = {}, configuredRule = null) {
    const kind = ruleKind(record);
    const initial = configuredRule ? {
      ...profile,
      required: configuredRule.required,
      forbidden: configuredRule.forbidden
    } : profile;
    const area = document.createElement('div');
    area.className = 'rule-grid';

    if (kind === 'setup') {
      const note = document.createElement('span');
      note.className = 'rule-hint';
      note.textContent = 'プロンプトへ復帰し、ログにエラーがなければ実行成功と判定します。';
      area.append(note);
    } else if (kind === 'serial') {
      area.classList.add('rule-single');
      area.append(makeField('期待する機器シリアル番号', 'input', 'serial', profile.serial || '', 'CSV読込時は SerialNumber 列を優先して照合'));
    } else if (kind === 'config') {
      area.append(makeField('必須設定', 'textarea', 'required', initial.required || '', '1行ごとに指定。CSV設定が優先されます。${列名} で機器CSVの値を指定できます。'));
      area.append(makeField('禁止設定', 'textarea', 'forbidden', initial.forbidden || '', '任意。CSV設定が優先されます。${列名} で機器CSVの値を指定できます。'));
    } else {
      area.append(makeField('出力に必要な文字列', 'textarea', 'required', initial.required || '', '各行がすべて含まれるとPASS。CSV設定可、${列名} で機器CSVの値を指定できます。'));
      area.append(makeField('出力にあってはいけない文字列', 'textarea', 'forbidden', initial.forbidden || '', '任意。1行でも含まれるとFAIL。CSV設定可、${列名} で機器CSVの値を指定できます。'));
    }

    card.append(area);
    area.querySelectorAll('[data-rule]').forEach(control => {
      control.addEventListener('input', () => {
        saveProfile();
        evaluateAll();
      });
    });
  }

  function renderGroup(group) {
    const section = document.createElement('section');
    section.className = 'log-group';
    section.dataset.groupKey = group.key;
    const header = document.createElement('div');
    header.className = 'group-head';
    const name = document.createElement('span');
    name.className = 'group-name';
    name.textContent = group.name;
    const deviceMatch = deviceForGroup(group);
    const deviceStatus = document.createElement('span');
    deviceStatus.className = 'group-total';
    deviceStatus.textContent = deviceMatch.row
      ? `CSV: ${csvValue(deviceMatch.row, 'Hostname') || csvValue(deviceMatch.row, 'DeviceID') || '機器行一致'}`
      : `CSV: ${deviceMatch.reason}`;
    const total = document.createElement('span');
    total.className = 'group-total';
    total.dataset.groupTotal = '';
    total.textContent = `${group.records.length} 項目`;
    const list = document.createElement('div');
    list.className = 'items';
    section.append(header, list);
    header.append(name, deviceStatus, total);
    const profile = readProfile(group.key);
    const commandOccurrences = new Map();

    group.records.forEach((record, index) => {
      const normalizedCommand = normalize(record.command);
      const occurrence = (commandOccurrences.get(normalizedCommand) || 0) + 1;
      commandOccurrences.set(normalizedCommand, occurrence);
      const profileRecordKey = `${normalizedCommand}#${occurrence}`;
      const configuredRule = ruleForCommand(record.command);
      const card = document.createElement('article');
      card.className = 'item';
      card.dataset.index = String(index);
      card.dataset.profileRecordKey = profileRecordKey;
      card.dataset.groupKey = group.key;
      card.dataset.profileKey = group.key;
      card.dataset.state = 'pending';

      const head = document.createElement('div');
      head.className = 'item-head';
      const number = document.createElement('span');
      number.className = 'number';
      number.textContent = String(index + 1).padStart(2, '0');
      const info = document.createElement('div');
      info.className = 'command-info';
      const command = document.createElement('code');
      command.className = 'command';
      command.textContent = record.command;
      const message = document.createElement('span');
      message.className = 'message';
      message.dataset.message = '';
      const status = document.createElement('span');
      status.className = 'status';
      status.dataset.status = '';
      status.textContent = '未判定';
      info.append(command, message);
      head.append(number, info, status);
      card.append(head);

      addRules(card, record, profile[profileRecordKey] || {}, configuredRule);

      const details = document.createElement('details');
      details.className = 'observed';
      const summaryNode = document.createElement('summary');
      summaryNode.textContent = '機器の出力を表示';
      const pre = document.createElement('pre');
      pre.dataset.output = '';
      details.append(summaryNode, pre);
      card.append(details);
      list.append(card);
    });
    resultList.append(section);
  }

  function renderItems() {
    resultList.replaceChildren();
    logGroups.forEach(renderGroup);
    const total = logGroups.reduce((sum, group) => sum + group.records.length, 0);
    document.getElementById('itemCount').textContent = `${total} 項目 / ${logGroups.length} ログ`;
    document.getElementById('empty').hidden = logGroups.length > 0;
  }

  function setItem(card, state, status, message, output) {
    card.dataset.state = state;
    card.querySelector('[data-status]').textContent = status;
    card.querySelector('[data-message]').textContent = message;
    card.querySelector('[data-output]').textContent = output || '（出力なし）';
  }

  function checkSerial(record, card) {
    const group = logGroups.find(item => item.key === card.dataset.groupKey);
    const deviceMatch = group ? deviceForGroup(group) : { row: null, reason: 'ロググループがありません' };
    const expected = (deviceRows.length && csvValue(deviceMatch.row, 'SerialNumber'))
      || card.querySelector('[data-rule="serial"]').value.trim();
    const found = extractSerials(record.output);
    if (!expected && deviceRows.length && found.length) {
      return deviceMatch.row
        ? { state: 'pending', status: 'CSV要確認', message: '一致したCSV行にSerialNumberの値がありません。' }
        : { state: 'fail', status: 'FAIL', message: `CSV照合不可（${deviceMatch.reason}）: ${found.map(item => item.value).join(', ')}` };
    }
    if (!expected) return { state: 'pending', status: '条件未設定', message: found.length ? `候補: ${found.map(item => `${item.label} ${item.value}`).join(' / ')}` : '期待シリアル番号を入力してください。' };
    if (!found.length) return { state: 'pending', status: '要確認', message: '対象シリアル番号を出力から検出できません。' };
    const match = found.find(item => item.value.toLocaleUpperCase() === expected.toLocaleUpperCase());
    return match
      ? { state: 'pass', status: 'PASS', message: `${match.label}: ${match.value} が一致` }
      : { state: 'fail', status: 'FAIL', message: `検出値: ${found.map(item => item.value).join(', ')}` };
  }

  function checkConfig(record, card) {
    const group = logGroups.find(item => item.key === card.dataset.groupKey);
    const requiredResult = expandCsvValues(card.querySelector('[data-rule="required"]').value, group);
    const forbiddenResult = expandCsvValues(card.querySelector('[data-rule="forbidden"]').value, group);
    if (requiredResult.error || forbiddenResult.error) return { state: 'pending', status: 'CSV要確認', message: requiredResult.error || forbiddenResult.error };
    const requiredText = requiredResult.value;
    const forbiddenText = forbiddenResult.value;
    const requiredLines = requiredText.replace(/\r/g, '').split('\n').filter(line => line.trim() && line.trim() !== '!');
    const forbiddenLines = forbiddenText.replace(/\r/g, '').split('\n').filter(line => line.trim() && line.trim() !== '!');
    if (!requiredLines.length && !forbiddenLines.length) return { state: 'pending', status: '条件未設定', message: '必須設定または禁止設定を入力してください。' };

    const actualLines = configLines(record.output);
    if (!actualLines.length) return { state: 'pending', status: '要確認', message: 'show runの設定本文を検出できません。' };
    const actual = configEntries(actualLines, false);
    const required = configEntries(requiredLines, false);
    const forbidden = configEntries(forbiddenLines, true);
    const missing = required.filter(entry => !actual.some(item => item.value === entry.value && (entry.scope === '*' || entry.scope === item.scope)));
    const present = forbidden.filter(entry => actual.some(item => item.value === entry.value && (entry.scope === '*' || entry.scope === item.scope)));
    const details = [];
    if (missing.length) details.push(`不足: ${missing.map(entry => entry.original).join(' / ')}`);
    if (present.length) details.push(`禁止設定あり: ${present.map(entry => entry.original).join(' / ')}`);
    if (!details.length) details.push(`${required.length}個の必須条件を満たし、禁止設定なし`);
    return { state: missing.length || present.length ? 'fail' : 'pass', status: missing.length || present.length ? 'FAIL' : 'PASS', message: details.join(' | ') };
  }

  function checkText(record, card) {
    const group = logGroups.find(item => item.key === card.dataset.groupKey);
    const requiredResult = expandCsvValues(card.querySelector('[data-rule="required"]').value, group);
    const forbiddenResult = expandCsvValues(card.querySelector('[data-rule="forbidden"]').value, group);
    if (requiredResult.error || forbiddenResult.error) return { state: 'pending', status: 'CSV要確認', message: requiredResult.error || forbiddenResult.error };
    const required = splitRules(requiredResult.value);
    const forbidden = splitRules(forbiddenResult.value);
    if (!required.length && !forbidden.length) return { state: 'pending', status: '条件未設定', message: '含むべき文字列を入力してください。' };
    const actual = normalize(record.output);
    const missing = required.filter(value => !actual.includes(normalize(value)));
    const present = forbidden.filter(value => actual.includes(normalize(value)));
    const messages = [];
    if (missing.length) messages.push(`不足: ${missing.join(' / ')}`);
    if (present.length) messages.push(`禁止文字列あり: ${present.join(' / ')}`);
    if (!messages.length) messages.push('指定した文字列条件を満たしています。');
    return { state: missing.length || present.length ? 'fail' : 'pass', status: missing.length || present.length ? 'FAIL' : 'PASS', message: messages.join(' | ') };
  }

  function evaluateRecord(record, card) {
    if (!record.found) return { state: 'missing', status: 'ログなし', message: 'このコマンドの実行行がログに見つかりません。' };
    if (!record.complete) return { state: 'pending', status: '未完了', message: '終了プロンプトが見つかりません。ログが途中で切れている可能性があります。' };
    if (errorPattern.test(record.output)) return { state: 'fail', status: 'FAIL', message: '機器出力にコマンドエラーを検出しました。' };

    const kind = ruleKind(record);
    if (kind === 'setup') return { state: 'pass', status: 'PASS', message: 'ログに実行行があり、次のプロンプトまで復帰しています。' };
    if (kind === 'serial') return checkSerial(record, card);
    if (kind === 'config') return checkConfig(record, card);
    return checkText(record, card);
  }

  function evaluateAll() {
    const cards = [...resultList.querySelectorAll('.item')];
    const totals = { pass: 0, fail: 0, pending: 0, missing: 0 };
    const groupTotals = new Map();

    cards.forEach((card, index) => {
      const record = records[index];
      const result = evaluateRecord(record, card);
      setItem(card, result.state, result.status, result.message, record.output);
      totals[result.state] += 1;
      const groupKey = card.dataset.groupKey;
      if (!groupTotals.has(groupKey)) groupTotals.set(groupKey, { pass: 0, fail: 0, pending: 0, missing: 0 });
      groupTotals.get(groupKey)[result.state] += 1;
    });

    for (const group of logGroups) {
      const groupTotal = groupTotals.get(group.key) || { pass: 0, fail: 0, pending: 0, missing: 0 };
      const groupTitle = resultList.querySelector(`[data-group-key="${CSS.escape(group.key)}"] [data-group-total]`);
      if (groupTitle) {
        groupTitle.textContent = `${groupTotal.pass} PASS · ${groupTotal.fail} FAIL · ${groupTotal.pending + groupTotal.missing} 未判定`;
      }
    }

    const countList = document.getElementById('counts');
    countList.replaceChildren();
    const labels = [['pass', 'PASS'], ['fail', 'FAIL'], ['pending', '未判定'], ['missing', 'ログなし']];
    labels.forEach(([key, label]) => {
      if (!totals[key]) return;
      const chip = document.createElement('span');
      chip.className = 'count';
      chip.textContent = `${label} ${totals[key]}`;
      countList.append(chip);
    });

    const title = document.getElementById('summaryTitle');
    const detail = document.getElementById('summaryDetail');
    if (!logGroups.length) {
      summary.dataset.state = 'pending';
      title.textContent = 'logs の機器フォルダーを選択してください';
      detail.textContent = configurationMessage || 'フォルダー内の各ログからテスト項目を作成します。';
      return;
    }
    if (!cards.length) {
      summary.dataset.state = 'pending';
      title.textContent = 'ログからコマンドを検出できません';
    } else if (totals.fail) {
      summary.dataset.state = 'fail';
      title.textContent = 'FAIL を検出しました';
    } else if (totals.missing || totals.pending) {
      summary.dataset.state = 'pending';
      title.textContent = totals.missing ? '未完了の項目があります' : '未判定の項目があります';
    } else {
      summary.dataset.state = 'pass';
      title.textContent = 'すべてのテスト項目が PASS です';
    }
    const commandCount = logGroups.reduce((sum, group) => sum + group.records.length, 0);
    detail.textContent = `${logName.title || logName.textContent} · ${logGroups.length} ログ / ${commandCount} コマンド${configurationMessage ? ` · ${configurationMessage}` : ''}`;
  }

  function updateRecords() {
    records = logGroups.flatMap(group => group.records);
    renderItems();
    evaluateAll();
  }

  document.getElementById('openLog').addEventListener('click', () => logPicker.click());

  logPicker.addEventListener('change', async () => {
    const files = [...(logPicker.files || [])]
      .filter(file => /\.log$/i.test(file.name))
      .sort((left, right) => left.webkitRelativePath.localeCompare(right.webkitRelativePath, undefined, { numeric: true }));
    if (!files.length) {
      logGroups = [];
      logName.textContent = '選択フォルダーに .log がありません';
      logName.title = '';
      updateRecords();
      return;
    }
    try {
      const loaded = await Promise.all(files.map(async file => ({
        file,
        text: await readFile(file),
        path: file.webkitRelativePath || file.name
      })));
      logGroups = loaded.map(({ file, text, path }) => {
        const parts = path.split(/[\\/]/).filter(Boolean);
        return {
          name: file.name,
          path,
          folder: parts.length > 1 ? parts[parts.length - 2] : '',
          key: parts.slice(-2).join('/').toLocaleLowerCase(),
          records: splitLog(text)
        };
      });
      const firstPath = loaded[0].path.split(/[\\/]/).filter(Boolean);
      const folderName = firstPath.length > 1 ? firstPath[0] : '選択フォルダー';
      logName.textContent = `${folderName} · ${logGroups.length} ログ`;
      logName.title = folderName;
      updateRecords();
    } catch (error) {
      document.getElementById('summaryTitle').textContent = error.message;
    }
  });

  updateRecords();
  loadDefaultCsvFiles();
})();
