'use strict';

const { configs } = require('@salesforce/eslint-config-lwc');

module.exports = [
    {
        ignores: [
            '**/lwc/**/*.css',
            '**/lwc/**/*.html',
            '**/lwc/**/*.json',
            '**/lwc/**/*.svg',
            '**/lwc/**/*.xml',
            '**/aura/**/*.auradoc',
            '**/aura/**/*.cmp',
            '**/aura/**/*.css',
            '**/aura/**/*.design',
            '**/aura/**/*.evt',
            '**/aura/**/*.json',
            '**/aura/**/*.svg',
            '**/aura/**/*.tokens',
            '**/aura/**/*.xml',
            '**/aura/**/*.app',
            '.sfdx/**',
        ],
    },
    ...configs.recommended,
];
