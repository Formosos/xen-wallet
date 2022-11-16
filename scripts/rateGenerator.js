// Used to calculate cumulativeWeeklyRewardMultiplier

const precisionMultiplier = 10 ** 9;

const calcRate = (_precisionMultiplier, _elapsedWeeks) => {
  // integrate a * 0.95^x from 0 to infinity = 2
  // solve => a = 0.102586724
  let _current = _precisionMultiplier * 0.102586724;
  let _cumulative = _current;
  for (let i = 0; i < _elapsedWeeks; ++i) {
    _current = (_current * 95) / 100;
    _cumulative += _current;
  }
  return _cumulative;
};

const rates = [];

for (let i = 0; i < 250; i++) {
  const rewardMultiplier = Math.floor(calcRate(precisionMultiplier, i));
  rates.push(rewardMultiplier);
  console.log(`cumulativeWeeklyRewardMultiplier[${i}] = ${rewardMultiplier};`)
}
