let original = 10000;
const precisionBooster = 100000;

const calcRate = (_original, _elapsedWeeks) => {
  let _current = (2 * _original) / (1 + _elapsedWeeks);
  let _cumulative = _current;
  for (let i = 0; i < _elapsedWeeks; ++i) {
    _current = (_current * 95) / 100;
    _cumulative += _current;
  }
  return _cumulative;
};

const rates = [];

for (let i = 0; i < 1000; i++) {
  const res = calcRate(original, i);
  const percentage = Math.floor(res / original * precisionBooster);
  rates.push(percentage);

  console.log(`precalculatedRates[${i}] = ${percentage};`)
}
