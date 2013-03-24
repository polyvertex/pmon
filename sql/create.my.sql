-- phpMyAdmin SQL Dump
-- version 3.5.7
-- http://www.phpmyadmin.net
--
-- Host: localhost
-- Generation Time: Mar 24, 2013 at 09:18 AM
-- Server version: 5.1.66-0+squeeze1
-- PHP Version: 5.3.3-7+squeeze15

SET SQL_MODE="NO_AUTO_VALUE_ON_ZERO";
SET time_zone = "+00:00";

--
-- Database: `pmon`
--

-- --------------------------------------------------------

--
-- Table structure for table `graph`
--

CREATE TABLE IF NOT EXISTS `graph` (
  `uniqname` varchar(255) COLLATE latin1_general_ci NOT NULL,
  `machine_id` int(10) unsigned NOT NULL,
  `unix` int(10) unsigned NOT NULL,
  `days` int(10) unsigned NOT NULL,
  `defname` varchar(255) COLLATE latin1_general_ci NOT NULL,
  `title` varchar(255) COLLATE latin1_general_ci NOT NULL,
  `file` varchar(255) COLLATE latin1_general_ci NOT NULL,
  PRIMARY KEY (`uniqname`)
) ENGINE=MyISAM DEFAULT CHARSET=latin1 COLLATE=latin1_general_ci;

-- --------------------------------------------------------

--
-- Table structure for table `log`
--

CREATE TABLE IF NOT EXISTS `log` (
  `id` bigint(20) unsigned NOT NULL AUTO_INCREMENT,
  `unix` int(10) unsigned NOT NULL,
  `machine_id` int(10) unsigned NOT NULL,
  `key` varchar(255) COLLATE latin1_general_ci NOT NULL,
  `value` varchar(255) COLLATE latin1_general_ci NOT NULL,
  PRIMARY KEY (`id`)
) ENGINE=MyISAM  DEFAULT CHARSET=latin1 COLLATE=latin1_general_ci;

-- --------------------------------------------------------

--
-- Table structure for table `logatom`
--

CREATE TABLE IF NOT EXISTS `logatom` (
  `id` bigint(20) unsigned NOT NULL AUTO_INCREMENT,
  `machine_id` int(10) unsigned NOT NULL,
  `key` varchar(255) COLLATE latin1_general_ci NOT NULL,
  `unix_first` int(10) unsigned NOT NULL,
  `unix_last` int(10) unsigned NOT NULL,
  `value` varchar(255) COLLATE latin1_general_ci NOT NULL,
  PRIMARY KEY (`id`)
) ENGINE=MyISAM  DEFAULT CHARSET=latin1 COLLATE=latin1_general_ci;

-- --------------------------------------------------------

--
-- Table structure for table `machine`
--

CREATE TABLE IF NOT EXISTS `machine` (
  `id` int(10) unsigned NOT NULL AUTO_INCREMENT,
  `name` varchar(255) COLLATE latin1_general_ci NOT NULL,
  `unix` int(10) unsigned DEFAULT NULL,
  `uptime` int(10) unsigned DEFAULT NULL,
  PRIMARY KEY (`id`),
  UNIQUE KEY `name` (`name`)
) ENGINE=MyISAM  DEFAULT CHARSET=latin1 COLLATE=latin1_general_ci;
