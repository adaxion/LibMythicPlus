# LibMythicPlus

A World of Warcraft (WoW) Addon designed to facilitate development of _other_ addons that deal with Mythic+ or Keystones. This library helps provide
a more consistent, normalized, easy-to-use API for retrieiving Mythic+ information, responding to events, and handling scenarios that Blizzard's API
does not easily account for. Please check out the section below "Notable Features" for a more detailed look at what this library provides over
Blizzard's standard APIs.

> Please note! While player user's are required to install this addon directly it provides no player-facing functionality by itself. Some other
> addon that provides a UI or other functionality should be installed in addition to this addon!

## Installation

While the addon is in development and during it's beta testing the installation process will involve downloading a zipfile from GitHub and installing
it in your WoW addon folder directly. When the addon is ready for publishing it should be made available through all major WoW addon distribution
platforms.

## Notable Features

- Consistent API to provide robust, rich information on keystones and Mythic+ Challenges. Wrangles together the various, disparate Blizzard APIs into
  something cohesive and easier to work with.
- Provides more semantic events and events missing from Blizzard's API. For example, provides an event for a Mythic+ being abandoned, including
  detailed information about why the run was abandoned.

## Usage Guide

As this addon continues through beta testing and readies for publishing a complete usage guide will be detailed here.

