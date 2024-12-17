#! /bin/bash


###SBATCH --ntasks=16
###SBATCH --nodes=4
###SBATCH --ntasks-per-node=4
#SBATCH --time=00:00:10
#SBATCH --partition=testing

orderedPainting.sh -g example1/simulatedData_N50.hap  -l example1/strainName_N50.txt 2>&1'
