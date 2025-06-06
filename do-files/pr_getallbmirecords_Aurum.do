*********************
*********************
****Modified on 13 April 2021 by Angel Wong
****Line 45-46: requires patient file, numunitfile from CPRD Aurum (all variables are in string when import)
****Line 41: drop if value is missing

* Requirements: datacheck function available through ssc install

**********************
**********************


/*Summary of key decisions implemented in this file
- drop if age < 16
- from age 16 , decided to allow heights to carry forward if missing 
- drop if 3+ measurements on the same day"
- if 2 mmts on same day: drop if >5cm (ht)/1kg (wt) diff, otherwise take the mean"
- initial pass, drop weights less than 2kg, heights less than 40cm"
- later, drops weights < 20kg, heights less than 4 or more than 7 feet "
- fills in missing heights using LOCF or if no previous, first future ht mmt"
- calculates a version of bmi directly from ht and wt"
- drops bmis <5 or >200 (but if GPRD and calculated version differ, and one is in the range 10-100, uses the sensible one)"
- in general, prioritises calculated bmi, and only uses GPRD version if cannot be calculated (as no ht mmt available at all)"
- determines BMI in 5 years prior to index date
*/

* Import data
foreach grp in antivegf cataract photocoag {
	
	display in red "*******************Observation file number: 1*******************"
	tempfile tempfile 
	use "$rawdata\\`grp'\observation_1", clear
	
	merge m:1 patid using "$savedir\\`grp'\cr_study_pop", keepusing(patid yob index_date) keep(match) nogen
	
	merge m:1 medcodeid using "$savedir\codelists\cprd_aurum_bmi_codes", keep(match) nogen
	
	merge m:1 numunitid using "$rawdata\NumUnit", keep(master match) keepusing(description) nogen
	
	save `tempfile', replace
	
		/*******************************************************************************
	#A2. Loop through subsequent (from 2 onwards) separate test extract files in 
		turn and append the results to the first extract file saved in #1
	*******************************************************************************/
	if "`grp'"=="antivegf" {
		local j 5
	}
	if "`grp'"=="cataract" {
		local j 74
	}
	if "`grp'"=="photocoag" {
		local j 3
	}
	di `j'
	forvalues n=2/`j' {
		display in red "*******************Observation file number: `n'*******************"

		use "$rawdata\\`grp'\observation_`n'", clear
		
		merge m:1 patid using "$savedir\\`grp'\cr_study_pop", keepusing(patid yob index_date) keep(match) nogen
			
		merge m:1 medcodeid using "$savedir\codelists\cprd_aurum_bmi_codes", keep(match) nogen

		merge m:1 numunitid using "$rawdata\NumUnit", keep(master match) keepusing(description) nogen
		* add the file containing records for the specified comorbidity
		* to make one file containing all specified comorbidiy records for the
		* clinical extract specified
		append using `tempfile'
		
		* save
		save `tempfile', replace
	}

	* Format observation date 
	gen obsdate1 = date(obsdate, "DMY")
	drop obsdate 
	rename obsdate1 obsdate
	drop if obsdate==.
		
	di "Number of records of height or weight/bmi imported = " r(N)

	di "Approximate date of birth as 15th June on the year of birth, to calculate age at mmt..."

	gen ageatmmt = (obsdate - mdy(6, 15, yob))/365.25
	noi di "... dropping record if aged <16 yrs at measurement"
	noi drop if ageatmmt<16

	*Put weight,height and BMI data into a variable enttype/data3, to fit in with below code
	gen enttype=13 if weight==9
	replace enttype=14 if height==9
	replace enttype=15 if bmi==9
	rename value data1 

	*Convert heights in cm into meters - AURUM ADDITION
	replace data1=data1/100 if enttype==14 & (desc=="cm" | desc=="cms") 

	*Drop implausible heights, BMI and weights (less than a newborn, min 2kg, 40cm)
	noi di "Dropping records where weight < 2kg or height < 40cm"
	noi drop if enttype==13 & data1<2 
	noi drop if enttype==14 & data1<0.4 
	noi drop if enttype==15 & data1>=200

	*Drop duplicate heights, BMI and weights on the same day or (for heights) if duplicated in m then cm
	noi di "Dropping duplicate heights or weights on the same day (or duplicate heights where one in m one in cm"
	noi bys patid obsdate enttype: drop if data1==data1[_n-1]
	noi bys patid obsdate enttype: drop if data1>=99*data1[_n-1] & data1<=101*data1[_n-1] & enttype==14

	*Drop if >2 ht/wt/bmi mmts on the same day
	noi di "Drop records where 3+ measurements on the same day"
	noi bys patid obsdate enttype: drop if _N>2

	datacheck _N==1, by(patid obsdate enttype) nol flag

	*Deal with remaining with >1 mmt on same day
	*If 2, and within 5cm (ht) or 1kg (wt) or 1 BMI, take the average, otherwise drop all
	noi di "Dealing with 2 different mmts on the same day..."
	bys patid obsdate enttype: gen diff=data1-data1[_n-1] if _n==2 & _c==1
	bys patid obsdate enttype: replace diff=diff[2]  if _n==1 & _N==2 & _c==1
	noi di "... if 2 weights >1kg difference, drop both"
	noi drop if diff>1 & diff<. & enttype==13 & _c==1
	noi di "... if 2 heights >5cm difference, drop both"
	noi drop if diff>.05 & diff<. & enttype==14 & _c==1
	noi di "... if 2 BMI >1 difference, drop both"
	noi drop if diff>1 & diff<. & enttype==15 & _c==1
	noi di "For the remainder, take the mean of the 2 mmts and keep 1 record"
	drop diff
	bys patid obsdate enttype: egen data1av = mean(data1) if _c==1
	noi replace data1 = data1av if _c==1 
	drop data1av 
	bys patid obsdate enttype: drop if _n>1 & _c==1

	drop _contra
	noi di "Now we have max one height and/or one weight record per patient on any given date..."
	bys patid obsdate enttype: assert _N==1

	noi di "...reshaping wide to create one record per patient per mmt date, with weight and/or bmi and/or height..."
	keep patid obsdate enttype data1 ageatmmt index_date
	reshape wide data1, i(patid obsdate) j(enttype)

	rename data113 weight
	rename data114 height
	rename data115 bmi

	noi di "Dealing with missing heights"

	*Replicate the GPRD height policy (i.e. take the last one, or the first one for records pre- first height)
	*Note all records under 16 are already dropped so no probs about using <16 heights

	gen ageatlastht = ageatmmt if height<.
	by patid: replace ageatlastht = ageatlastht[_n-1] if height==. & ageatlastht[_n-1]<.
	noi di "Filling in missing heights"
	cou if height==. & ageatlastht<.
	local tottofill = r(N)
	cou if weight<.
	local totalwtrecords = r(N)
	noi di "Total number of records containing a weight : " `totalwtrecords'
	cou if weight<. & height==.
	local totmissinght = r(N)
	noi di "Total number of records containing a weight but no height: " r(N) " (" %3.1f 100*`totmissinght'/`totalwtrecords' "%)"
	cou if weight<. & height==. & ageatlastht<.
	local tottofill = r(N)
	noi di "Number of missing heights to be filled by locf (i.e. where a previous height was recorded): " `tottofill' " (" %3.1f 100*`tottofill'/`totmissinght' "% of those missing)"
	cou if weight<. & height==. & ageatmmt>21 & ageatlastht<18
	noi di "Number of missing heights aged over 21 where the last height was age<18: " r(N) " (" %3.1f 100*r(N)/`tottofill' "% of those being filled)"

	noi di "Filling in the heights with LOCF regardless of age..."
	noi by patid: replace height = height[_n-1] if height==. & height[_n-1]<.

	by patid: gen cumht = sum(height) if height<.
	by patid: egen firstht = min(cumht)
	cou if weight<. & height==. & firstht<.
	noi di "Number of missing heights that can be filled in using a future measurement: " r(N) " (" %3.1f 100*r(N)/`totmissinght' "% further of the original number missing)" 
	noi di "Filling in heights with future height..."
	noi replace height = firstht if height==.
	drop cumht firstht 
	cou if weight<. & height==.
	local remainingnoheight=r(N)
	noi di "This leaves " r(N) " (" %3.1f 100*r(N)/`totalwtrecords' "%) weight records with no height available at all..."
	cou if height==. & bmi<.
	noi di "...however " r(N) " (" %3.1f 100*r(N)/`remainingnoheight' "%) of these do have a bmi entered"

	noi di "Dropping height-only records as of no further use"
	noi drop if height<. & weight==. & bmi==.

	noi di "Now cleaning data to remove apparent errors where possible"

	noi di "If height is apparently in cm then convert to m (i.e. if the recorded height would correspond to 4-7ft in cm)"
	noi replace height = height/100 if height>121 & height<214 /*i.e. between 4 and 7 ft in cm*/

	noi di "Calculate bmi from weight and height, and compare with GPRD bmi field..."
	gen bmi_calc=weight/(height^2)
	gen discrep=bmi-bmi_calc

	*Note GPRD seem to round down the 1st DP regardless
	gen discreprnd=bmi-(floor(bmi_calc*10)/10)
	replace discreprnd=0 if discreprnd<0.0001
	replace discreprnd=0 if abs(discrep)<0.0001


	*If one sensible, one silly, take the sensible one
	noi di "If GPRD bmi is silly (<200 or <5) then replace with missing, and same for the calculated version..."
	noi replace bmi=. if (bmi>200|bmi<5) 
	noi replace bmi_calc=. if (bmi_calc>200|bmi_calc<5) 

	noi di ".. and now drop records where both GPRD bmi field amd calculated field are missing (which therefore also drops the silly ones)"
	noi drop if bmi==. & bmi_calc==. /*useless records*/

	*Drop record if height <4ft or >7ft 
	noi di "Drop records where height recorded is <4 of >7ft"
	noi drop if height<1.21
	noi drop if height>2.14 & height<.

	egen wtcat = cut(weight), at(0(1)25 30(5)100 1000)
	noi di "Weight distribution - note the peak between 10 and 20 - suggests recorded in stones?"
	noi tab wtcat /*note the peak between 10 and 20 - stones?*/
	noi di "Drop if weight<=20 as likely to be recorded in stones or error"
	noi drop if weight<=20 /*I think these have mostly been recorded in stones*/

	*Use calculated version where poss as no weird rounding 
	noi di "Prioritise calculated bmi (from wt/ht) as the one to use (preferable as GPRD version always appears to be rounded down)...  "
	noi di "...but fill in missing values in the calculated BMI, with GPRD BMI where it is available"
	noi replace bmi_calc=bmi if bmi_calc==.

	egen bmicat = cut(bmi_calc), at(0 5 6 7 8 9 10 11 12 13 14 15 20 30 40 50 60 70 80 90 100 110 120 130 140 150 160 170 180 190 200)
	di "Distribution of BMI records (before considering fup dates etc); note truncated at 5 and 200 by above processing, but may wish to restrict more in analysis...e.g. to 3 sds from mean?"
	tab bmicat

	drop bmi bmicat discrep* wtcat 
	rename bmi_calc bmi

	di "Total patients with at least one record"
	codebook patid

	* Keep only records up to a maximum 5 years prior to index date
	drop if obsdate > index_date 
	gen time_prior = index_date - obsdate 
	drop if time_prior >1827
	bys patid: egen closest_measure = min(time_prior)
	keep if closest_measure==time_prior 
	rename bmi bl_bmi 
	keep patid bl_bmi 
	save "$savedir\\`grp'\cr_bl_bmi", replace

}

