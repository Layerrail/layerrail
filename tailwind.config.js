/** @type {import('tailwindcss').Config} */
module.exports = {
  content: [
    "./views/**/*.erb",
    "./assets/js/app.js",
    "./assets/js/playground/**/*.{js,jsx}",
    "./helpers/web.rb",
  ],
  theme: {
    extend: {
      colors: {
        layerrail: {
          50: '#FEFDFE',
          100: '#EBE9F1',
          200: '#D1C8E7',
          300: '#BCB9C1',
          500: '#8B67F2',
          600: '#7957E6',
          700: '#6748C7',
          800: '#523A9D',
          900: '#5A3A38',
        },
      },
      keyframes: {
        flash: {
          '0%, 100%': { backgroundColor: 'transparent' },
          '50%': { backgroundColor: '#fef08a' },
        }
      },
      animation: {
        flash: 'flash 1s ease-in-out infinite',
      }
    },
  },
  plugins: [
    require('@tailwindcss/forms'),
    require('@tailwindcss/typography'),
  ],
  safelist: [
    ...[...Array(101).keys()].flatMap(i => `w-[${i}%]`),
    {
      pattern: /bg-[a-z]+-500/,
    },
    {
      pattern: /(bg|text|border|ring|outline|focus:ring|focus-visible:outline)-layerrail-(50|100|200|300|500|600|700|800|900)/,
    },
    ...['text-blue-600', 'text-green-400', 'text-amber-400', 'text-red-400',
    'text-sky-300', 'text-emerald-600', 'text-layerrail-500'],
    'transition-colors',
    'duration-1000',
    'border-red-500'
  ]
}
