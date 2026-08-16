// Pinned so timestamp handling is exercised somewhere other than UTC. A
// zone-less timestamp parsed as local time is indistinguishable from one parsed
// as UTC when the suite runs at offset 0, which is how a five-hour error in the
// scan-age bookmark survived a green test run. Phoenix observes no DST, so the
// offset is the same in every season.
process.env.TZ = 'America/Phoenix';

module.exports = {
  preset: 'ts-jest',
  testEnvironment: 'jsdom',
  roots: ['<rootDir>'],
  moduleDirectories: ['node_modules', 'js'],
  moduleNameMapper: {
    '^@/(.*)$': '<rootDir>/js/$1',
    '\.scss$': 'identity-obj-proxy', // Mock SCSS files
  },
  transform: {
    '^.+\.(ts|tsx)$': 'ts-jest',
    '^.+\.(js|jsx)$': 'babel-jest', // Add babel-jest for JS/JSX files if needed
  },
};
