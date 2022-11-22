// Used to calculate cumulativeWeeklyRewardMultiplier

const precisionMultiplier = 10 ** 9;

const calcRate = (precisionMultiplier, elapsedWeeks) => {
  // integrate a * 0.95^x from 0 to infinity = 2
  // solve => a = 0.10000026975
  let current = precisionMultiplier * 0.10000026975;
  let cumulative = current;
  for (let i = 0; i < elapsedWeeks; ++i) {
    current = (current * 95) / 100;
    cumulative += current;
  }
  return cumulative;
};

const rates = [];

for (let i = 0; i < 250; i++) {
  const rewardMultiplier = Math.floor(calcRate(precisionMultiplier, i));
  rates.push(rewardMultiplier);
  console.log(`cumulativeWeeklyRewardMultiplier[${i}] = ${rewardMultiplier};`)
}
