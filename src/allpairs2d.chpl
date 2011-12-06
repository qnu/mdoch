/****************************************************************************
 * Copyright (C) 2011  Nan Dun <dun@logos.ic.i.u-tokyo.ac.jp>
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>.
 * This program can be distributed under the terms of the GNU GPL.
 * See the file COPYING.
 ***************************************************************************/

/* allpairs2d.chpl */

use BlockDist, CyclicDist;
use common;

record mol2d {
	var r, rv, ra: vector2d;
	var onlocale: int;
}

var _initUcellX, _initUcellY: int;
config const deltaT: real = 0.005;
config const density: real = 0.8;
config const temperature: real = 1.0;
config const initUcellD: int = 0;
config const initUcellX: int = 0;
config const initUcellY: int = 0;
config const stepAvg: int = 100;
config const stepEquil: int = 0;
config const stepLimit: int = 10000;
config const profLevel: int = 0;
const NDIM: int = 2;

var rCut, rrCut, velMag, timeNow, uSum, virSum, vvSum: real;
var initUcell: vector2d_i; 
var region, vSum: vector2d;
var nMol, stepCount, moreCycles: int; 
var kinEnergy, totEnergy, pressure: prop;
var Space, BlockSpace: domain(1);
var molDom: domain(1);	// use domain to reallocate array
var mol: [molDom] mol2d;
var timer: elapsedTimer;
var uSumLock$: sync bool; // atomic statement is not ready yet

_initUcellX = 20;
_initUcellY = 20;
if initUcellD > 0  {
	_initUcellX = initUcellD;
	_initUcellY = initUcellD;
}
if initUcellX > 0 then _initUcellX = initUcellX;
if initUcellY > 0 then _initUcellY = initUcellY;

proc printConfig() {
	writeln(
		"deltaT          ", deltaT, "\n",
		"density         ", density, "\n",
		"initUcell       ", _initUcellX, " ",  _initUcellY, "\n",
		"stepAvg         ", stepAvg, "\n",
		"stepEquil       ", stepEquil, "\n",
		"stepLimit       ", stepLimit, "\n",
		"temperature     ", temperature, "\n",
		"----");
	stdout.flush();
}

proc init() {
	// Setup parameters
	initUcell = (_initUcellX, _initUcellY);
	rCut = 2.0 ** (1.0 / 6.0);
	rrCut = rCut ** 2;
	region = 1.0 / sqrt(density) * initUcell;
	nMol = initUcell.prod();
	velMag = sqrt(NDIM * (1.0 - 1.0 / nMol * temperature));
	stepCount = 0;

	// Allocate storage
	Space = [1..nMol];
//	BlockSpace = Space dmapped Block(boundingBox=Space);
	BlockSpace = Space dmapped Cyclic(startIdx=Space.low);
	molDom = [BlockSpace];
	kinEnergy = new prop();
	totEnergy = new prop();
	pressure = new prop();

	// Initial coordinates
	var c, gap: vector2d;
	var n: int;
	
	gap = region / initUcell;
	n = 1;
	for (ny, nx) in [0..initUcell.y-1, 0..initUcell.x-1] {
		mol(n).r = (nx + 0.5, ny + 0.5) * gap - (0.5 * region);
		n += 1;
	}

	// Initial velocities and accelerations
	vSum.zero();
	for m in mol {
		m.rv = velMag * vrand2d();
		vSum += m.rv;
	}
	for m in mol {
		m.rv += (-1.0 / nMol) * vSum;
		m.ra.zero();	// accelerations
	}
	
	totEnergy.zero();
	kinEnergy.zero();
	pressure.zero();
}

proc step() {
	stepCount += 1;
	timeNow = stepCount * deltaT;
	
	for m in mol {
		// Leapfrog
		m.rv += (0.5 * deltaT) * m.ra;
		m.r += deltaT * m.rv;
		// Apply boundary condition
		m.r = vwrap(m.r, region);
		// Re-initial acceleration
		m.ra.zero();
	}

	// Compute forces
	uSum = 0;
	virSum = 0;
	uSumLock$.reset();
	uSumLock$ = true;

	coforall m in mol {
		var dr: vector2d;
		var fcVal, rr, rri, rri3: real;
		var uSumLocal, virSumLocal: real;
		m.onlocale = here.id;
		uSumLocal = 0.0;
		virSumLocal = 0.0;
		for m2 in mol {
			dr = vwrap((m.r - m2.r), region);
			rr = dr.lensq();
			if rr > 0 && rr < rrCut {
				rri = 1.0 / rr;
				rri3 = rri ** 3;
				fcVal = 48 * rri3 * (rri3 - 0.5) * rri;
				m.ra += fcVal * dr;
				uSumLocal += (4 * rri3 * (rri3 - 1.0) + 1) * 0.5;
				virSumLocal += fcVal * rr * 0.5;
			}
		}
		uSumLock$;
		uSum += uSumLocal;
		virSum += virSumLocal;
		uSumLock$ = true;
	}
	
	// Leafrog
	for m in mol do	m.rv += (0.5 * deltaT) * m.ra;
	for m in mol do	writeln(m.onlocale);

	// Evaluate thermodynamics properties
	vSum.zero();
	vvSum = 0;
	// reduce does not support operator overloading?
	for m in mol do vSum += m.rv;
	vvSum = + reduce (mol.rv.lensq());
	kinEnergy.v = 0.5 * vvSum / nMol;
	totEnergy.v = kinEnergy.v + uSum / nMol;
	pressure.v = density * (vvSum + virSum) / (nMol * NDIM);
		
	// Accumulate thermodynamics properties
	totEnergy.acc();
	kinEnergy.acc();
	pressure.acc();
		
	if stepCount % stepAvg == 0 {
		totEnergy.avg(stepAvg);
		kinEnergy.avg(stepAvg);
		pressure.avg(stepAvg);

		// Print summary
		writeln("\t", stepCount, "\t", timeNow, 
			"\t", (vSum.x + vSum.y) / nMol,
			"\t", totEnergy.sum, "\t", totEnergy.sum2,
			"\t", kinEnergy.sum, "\t", kinEnergy.sum2,
			"\t", pressure.sum, "\t", pressure.sum2);
		stdout.flush();
		
		totEnergy.zero();
		kinEnergy.zero();
		pressure.zero();
	}
}

proc main() {
	printConfig();
	init();
	moreCycles = 1;
	while (moreCycles) {
		step();
		if (stepCount >= stepLimit) then moreCycles = 0;
	};
}
