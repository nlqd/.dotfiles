#!/usr/bin/env node

// Simple Vietnamese lunar calendar converter
// Using algorithm from: https://www.informatik.uni-leipzig.de/~duc/amlich/

function jdFromDate(dd, mm, yy) {
  let a = Math.floor((14 - mm) / 12);
  let y = yy + 4800 - a;
  let m = mm + 12 * a - 3;
  let jd = dd + Math.floor((153 * m + 2) / 5) + 365 * y + Math.floor(y / 4) - Math.floor(y / 100) + Math.floor(y / 400) - 32045;
  if (jd < 2299161) {
    jd = dd + Math.floor((153 * m + 2) / 5) + 365 * y + Math.floor(y / 4) - 32083;
  }
  return jd;
}

function getNewMoonDay(k, timeZone) {
  let T = k / 1236.85;
  let T2 = T * T;
  let T3 = T2 * T;
  let dr = Math.PI / 180;
  let Jd1 = 2415020.75933 + 29.53058868 * k + 0.0001178 * T2 - 0.000000155 * T3;
  Jd1 = Jd1 + 0.00033 * Math.sin((166.56 + 132.87 * T - 0.009173 * T2) * dr);
  let M = 359.2242 + 29.10535608 * k - 0.0000333 * T2 - 0.00000347 * T3;
  let Mpr = 306.0253 + 385.81691806 * k + 0.0107306 * T2 + 0.00001236 * T3;
  let F = 21.2964 + 390.67050646 * k - 0.0016528 * T2 - 0.00000239 * T3;
  let C1 = (0.1734 - 0.000393 * T) * Math.sin(M * dr) + 0.0021 * Math.sin(2 * dr * M);
  C1 = C1 - 0.4068 * Math.sin(Mpr * dr) + 0.0161 * Math.sin(dr * 2 * Mpr);
  C1 = C1 - 0.0004 * Math.sin(dr * 3 * Mpr);
  C1 = C1 + 0.0104 * Math.sin(dr * 2 * F) - 0.0051 * Math.sin(dr * (M + Mpr));
  C1 = C1 - 0.0074 * Math.sin(dr * (M - Mpr)) + 0.0004 * Math.sin(dr * (2 * F + M));
  C1 = C1 - 0.0004 * Math.sin(dr * (2 * F - M)) - 0.0006 * Math.sin(dr * (2 * F + Mpr));
  C1 = C1 + 0.001 * Math.sin(dr * (2 * F - Mpr)) + 0.0005 * Math.sin(dr * (2 * Mpr + M));
  let deltat;
  if (T < -11) {
    deltat = 0.001 + 0.000839 * T + 0.0002261 * T2 - 0.00000845 * T3 - 0.000000081 * T * T3;
  } else {
    deltat = -0.000278 + 0.000265 * T + 0.000262 * T2;
  }
  let JdNew = Jd1 + C1 - deltat;
  return Math.floor(JdNew + 0.5 + timeZone / 24);
}

function getLunarMonth11(yy, timeZone) {
  let off = jdFromDate(31, 12, yy) - 2415021;
  let k = Math.floor(off / 29.530588853);
  let nm = getNewMoonDay(k, timeZone);
  let sunLong = Math.floor((nm - 2415021) / 365.25 + 0.5);
  if (sunLong >= 9) {
    nm = getNewMoonDay(k - 1, timeZone);
  }
  return nm;
}

function convertSolar2Lunar(dd, mm, yy, timeZone) {
  let dayNumber = jdFromDate(dd, mm, yy);
  let k = Math.floor((dayNumber - 2415021.076998695) / 29.530588853);
  let monthStart = getNewMoonDay(k + 1, timeZone);
  if (monthStart > dayNumber) {
    monthStart = getNewMoonDay(k, timeZone);
  }
  let a11 = getLunarMonth11(yy, timeZone);
  let b11 = a11;
  let lunarYear;
  if (a11 >= monthStart) {
    lunarYear = yy;
    a11 = getLunarMonth11(yy - 1, timeZone);
  } else {
    lunarYear = yy + 1;
    b11 = getLunarMonth11(yy + 1, timeZone);
  }
  let lunarDay = dayNumber - monthStart + 1;
  let diff = Math.floor((monthStart - a11) / 29);
  let lunarMonth = diff + 11;
  if (b11 - a11 > 365) {
    let leapMonthDiff = Math.floor((getLunarMonth11(yy, timeZone) - a11) / 29);
    if (diff >= leapMonthDiff) {
      lunarMonth = diff + 10;
    }
  }
  if (lunarMonth > 12) {
    lunarMonth = lunarMonth - 12;
  }
  if (lunarMonth >= 11 && diff < 4) {
    lunarYear -= 1;
  }
  return [lunarDay, lunarMonth, lunarYear];
}

// Get today's date
const today = new Date();
const dd = today.getDate();
const mm = today.getMonth() + 1;
const yy = today.getFullYear();

// Vietnam timezone offset (GMT+7)
const timeZone = 7;

const [lunarDay, lunarMonth, lunarYear] = convertSolar2Lunar(dd, mm, yy, timeZone);

// Can chi (Heavenly Stems and Earthly Branches)
const can = ["Giáp", "Ất", "Bính", "Đinh", "Mậu", "Kỷ", "Canh", "Tân", "Nhâm", "Quý"];
const chi = ["Tý", "Sửu", "Dần", "Mão", "Thìn", "Tỵ", "Ngọ", "Mùi", "Thân", "Dậu", "Tuất", "Hợi"];

const yearCan = can[(lunarYear + 6) % 10];
const yearChi = chi[(lunarYear + 8) % 12];

console.log(`${lunarDay}/${lunarMonth}/${lunarYear} (${yearCan} ${yearChi})`);
