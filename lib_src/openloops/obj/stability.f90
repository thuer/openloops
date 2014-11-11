
! Copyright 2014 Fabio Cascioli, Jonas Lindert, Philipp Maierhoefer, Stefano Pozzorini
!
! This file is part of OpenLoops.
!
! OpenLoops is free software: you can redistribute it and/or modify
! it under the terms of the GNU General Public License as published by
! the Free Software Foundation, either version 3 of the License, or
! (at your option) any later version.
!
! OpenLoops is distributed in the hope that it will be useful,
! but WITHOUT ANY WARRANTY; without even the implied warranty of
! MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
! GNU General Public License for more details.
!
! You should have received a copy of the GNU General Public License
! along with OpenLoops.  If not, see <http://www.gnu.org/licenses/>.


module ol_stability
  use kind_types, only: dp
  implicit none
  real(dp), save :: last_relative_deviation = -1, last_vme2 = -1, last_vme2_scaled = -1
  contains


subroutine last_scaling_result(me1, me2, dev)
  implicit none
  real(dp), intent(out) :: me1, me2, dev
  me1 = last_vme2
  me2 = last_vme2_scaled
  dev = last_relative_deviation
end subroutine last_scaling_result


function check_stability_write(n)
  ! write stability log for n-th matrix element?
  ! stability_log = 0 --> .false. (never log)
  !                 1 --> adaptive, logarithmic
  !                 2 --> .true. (log every point)
  use ol_parameters_decl_dp, only: stability_log
  implicit none
  integer, intent(in) :: n
  logical :: check_stability_write
  integer :: log_bunch
  if (stability_log <= 1) then
    check_stability_write = .false.
  else if (stability_log == 2) then
    if (n < 200) then
      log_bunch = 10
    else if (n < 2000) then
      log_bunch = 100
    else if (n < 20000) then
      log_bunch = 1000
    else if (n < 200000) then
      log_bunch = 10000
    else if (n < 2000000) then
      log_bunch = 100000
    else
      log_bunch = 1000000
    end if
    check_stability_write = (mod(n,log_bunch) == 0)
  else if (stability_log == 3) then
    check_stability_write = .true.
  else
    print *, "[OpenLoops] ERROR: invalid value of stability_log:", stability_log
    print *, "                   must be 0(never) / 1(default:adaptive) / 2(always)"
    stop
  end if
end function check_stability_write


subroutine write_histogram(processname, hist, triggered)
  use ol_parameters_decl_dp, only: pid_string, stability_logdir
  implicit none
  character(len=*), intent(in) :: processname
  integer, intent(in) :: hist(20), triggered(:)
  character(len=100) :: outfile
  integer :: outunit = 44
  outfile = trim(stability_logdir) // "/histogram_" // trim(processname) // "_" // trim(pid_string) // ".log"
  open(unit=outunit, file=outfile, form='formatted')
  write(outunit,*) hist(20), '|', hist(19:1:-1), '|', triggered
  close(outunit)
end subroutine write_histogram


subroutine write_point(processname, psp, me)
  use ol_parameters_decl_dp, only: pid_string, stability_logdir
  implicit none
  character(len=*), intent(in) :: processname
  real(dp), intent(in), optional :: psp(:,:)
  real(dp), intent(in), optional :: me(:)
  character(len=100) :: outfile
  integer :: outunit = 44, k
  outfile = trim(stability_logdir) // "/points_" // trim(processname) // "_" // trim(pid_string) // ".log"
  open(unit=outunit, file=outfile, form='formatted', position='append')
  if (present(psp)) then
    write(outunit,*) ''
    do k = 1, size(psp,2)
      write(outunit,*) 'p= ', psp(:,k)
    end do
  else if (present(me)) then
    write(outunit,*) 'me=', psp(:,k)
  end if
  close(outunit)
end subroutine write_point


subroutine write_result(processname, data)
  use ol_parameters_decl_dp, only: pid_string, stability_logdir
  implicit none
  character(len=*), intent(in) :: processname
  real(dp), intent(in) :: data(:)
  character(len=100) :: outfile
  integer :: outunit = 44, k
  outfile = trim(stability_logdir) // "/points_" // trim(processname) // "_" // trim(pid_string) // ".log"
  open(unit=outunit, file=outfile, form='formatted', position='append')
  write(outunit,*) data
  close(outunit)
end subroutine write_result



! **********************************************************************
subroutine stability_trigger(processname, np, hist, &
   & abscorr_thr, trigeff_local, abscorr0, abscorr1, &
   & M2loop0, M2loop0_rescue, M2tree, sum_M2tree, P_scatt)
  ! **********************************************************************
  ! Mtree          = squared tree amplitude
  ! M2loop0        = fin. part of 1-loop*tree interference with default
  !                  reduction lib
  ! M2loop0_rescue = same with "rescue" reduction lib
  ! abscorr0       = abs(M2loop0/M2tree)
  ! abscorr1       = abs(M2loop0_rescue/M2tree)
  !
  ! np(1)          = tot # points
  ! np(2)          = # triggered points
  ! np(3)          = # unstable points
  ! np(4)          = # unstable>rescued points
  ! np(5)          = # bad>rescued points
  ! np(6)          = # killed points (correction set to 0)
  !
  ! hist(1)        = # points with agreement < Born*10^2
  ! hist(2)        = # points with agreement < Born*10^1
  ! ...
  ! hist(19)       = # points with agreement < Born*10^-16
  ! hist(20)       = number of points in the histogram (=np(2))
  !
  ! abscorr_thr    = threshold absolute correction above which stability
  !                  checks are triggered:
  ! trigeff_local  = fraction of points for which the stability-trigger condition
  !                  abscorr0 > abscorr_thr is fulfilled
  !                  (is computed with "relaxation time" 1/eps_relax)
  !                  abscorr_thr is adapted dynamically in such a way
  !                  that trigeff_local -> trigeff_target
  ! **********************************************************************
  use kind_types, only: dp
  use ol_loop_parameters_decl_dp, only: trigeff_targ, abscorr_unst, ratcorr_bad
  use ol_parameters_decl_dp, only: rONE, a_switch, a_switch_rescue, pid_string, stability_log, stability_logdir
  use ol_generic, only: relative_deviation
  implicit none
  character(*), intent(in)    :: processname
  integer,      intent(inout) :: np(8), hist(20)
  real(dp), intent(inout) :: abscorr_thr, trigeff_local, sum_M2tree, M2loop0, abscorr0
  real(dp), intent(in)    :: abscorr1, M2loop0_rescue, M2tree, P_scatt(:,:)
  character(100)  :: outfile
  character(14)  :: stabstatus
  real(dp) :: abscorr_avg, abscorr_dev, kfac_deviation
  integer        :: outunit = 44
  logical        :: iftrig, ifunstab, write_stab
  real(dp) :: M2loop0_in
  real(dp), parameter :: eps_relax = 0.002 ! relaxation speed of trigeff_local
  real(dp), parameter :: eps_adapt = 0.002 ! adaption speed of abscorr_thr

  M2loop0_in = M2loop0

  kfac_deviation = abs(M2loop0-M2loop0_rescue)/M2tree

  ! apply stability trigger to actual PS point
  if (abscorr0 <= abscorr_thr .and. trigeff_targ < 1) then
    iftrig = .false.
    ifunstab = .false.
    stabstatus = 'untrig'

  else if (kfac_deviation < abscorr_unst) then
    iftrig = .true.
    ifunstab = .false.
    stabstatus = 'stab>resc'
    M2loop0 = M2loop0_rescue
    np(2) = np(2) + 1

  else if (relative_deviation(M2loop0, M2loop0_rescue) < ratcorr_bad) then
    iftrig = .true.
    ifunstab = .true.
    stabstatus = 'unstab>resc'
    M2loop0 = M2loop0_rescue
    np(2) = np(2) + 1
    np(3) = np(3) + 1
    np(4) = np(4) + 1

  else if (abscorr1 <= abscorr_thr) then
    iftrig = .true.
    ifunstab = .true.
    stabstatus = 'bad>resc'
    M2loop0 = M2loop0_rescue
    np(2) = np(2) + 1
    np(3) = np(3) + 1
    np(5) = np(5) + 1

  else
    iftrig = .true.
    ifunstab = .true.
    stabstatus = 'bad>0'
    M2loop0 = 0 ! sets correction to zero
    np(2) = np(2) + 1
    np(3) = np(3) + 1
    np(6) = np(6) + 1

  end if

  ! update trigger parameters
  np(1) = np(1) + 1
  sum_M2tree = sum_M2tree + M2tree

  if (iftrig) then
    trigeff_local = trigeff_local*(1-eps_relax) + eps_relax
  else
    trigeff_local = trigeff_local*(1-eps_relax)
  endif

  if (trigeff_targ < 1) then
     abscorr_thr = abscorr_thr*(1+(trigeff_local/trigeff_targ-1)*eps_adapt)
  else
     abscorr_thr = 0
  endif

  if (iftrig) then
    if (kfac_deviation > 100)                hist( 1) = hist( 1) + 1
    if (kfac_deviation > 10)                 hist( 2) = hist( 2) + 1
    if (kfac_deviation > 1)                  hist( 3) = hist( 3) + 1
    if (kfac_deviation > 0.1)                hist( 4) = hist( 4) + 1
    if (kfac_deviation > 0.01)               hist( 5) = hist( 5) + 1
    if (kfac_deviation > 0.001)              hist( 6) = hist( 6) + 1
    if (kfac_deviation > 0.0001)             hist( 7) = hist( 7) + 1
    if (kfac_deviation > 0.00001)            hist( 8) = hist( 8) + 1
    if (kfac_deviation > 0.000001)           hist( 9) = hist( 9) + 1
    if (kfac_deviation > 0.0000001)          hist(10) = hist(10) + 1
    if (kfac_deviation > 0.00000001)         hist(11) = hist(11) + 1
    if (kfac_deviation > 0.000000001)        hist(12) = hist(12) + 1
    if (kfac_deviation > 0.0000000001)       hist(13) = hist(13) + 1
    if (kfac_deviation > 0.00000000001)      hist(14) = hist(14) + 1
    if (kfac_deviation > 0.000000000001)     hist(15) = hist(15) + 1
    if (kfac_deviation > 0.0000000000001)    hist(16) = hist(16) + 1
    if (kfac_deviation > 0.00000000000001)   hist(17) = hist(17) + 1
    if (kfac_deviation > 0.000000000000001)  hist(18) = hist(18) + 1
    if (kfac_deviation > 0.0000000000000001) hist(19) = hist(19) + 1
    hist(20) = hist(20) + 1
  end if

  if (stability_log > 0) then

    outfile = trim(stability_logdir) // "/stability_" // trim(processname) // "_" // trim(pid_string) // ".log"

    ! write output to stab files
    if (np(1) == 1) then
      open(unit=outunit,file=outfile,form='formatted')
      write(outunit,90) 'default-red', 'check-red', 'eps_relax','eps_adapt','abscorr_unst','ratcorr_bad', 'eff_targ'
      write(outunit,91) a_switch , a_switch_rescue, eps_relax, eps_adapt, abscorr_unst, ratcorr_bad, trigeff_targ
      write(outunit,*)
      write(outunit,*)
      write(outunit,101) 'ntot', 'tree/<tree>','corr0', 'corr1','corr1-corr0', 'stability', &
        & 'corr_thr', 'eff_local', 'eff_glob', 'unst/tot', 'unst>res/tot', 'bad>res/tot', 'killed/tot'
      close(outunit)
    end if

    write_stab = check_stability_write(np(1))

    if (ifunstab) then
      open(unit=outunit,file=outfile,position='append',form='formatted')
      write(outunit,102) np(1), M2tree*np(1)/sum_M2tree, M2loop0_in/M2tree, M2loop0_rescue/M2tree, &
        & (M2loop0_rescue-M2loop0_in)/M2tree, trim(stabstatus), &
        & abscorr_thr, trigeff_local, (rONE*np(2))/np(1), (rONE*np(3))/np(1), &
        & (rONE*np(4))/np(1), (rONE*np(5))/np(1), (rONE*np(6))/np(1)
      close(outunit)
    else if (write_stab) then
      if (iftrig) then
        open(unit=outunit,file=outfile,position='append',form='formatted')
        write(outunit,102) np(1), M2tree*np(1)/sum_M2tree, M2loop0_in/M2tree, M2loop0_rescue/M2tree, &
          & (M2loop0_rescue-M2loop0_in)/M2tree, trim(stabstatus), &
          & abscorr_thr, trigeff_local, (rONE*np(2))/np(1), (rONE*np(3))/np(1), &
          & (rONE*np(4))/np(1), (rONE*np(5))/np(1), (rONE*np(6))/np(1)
        close(outunit)
      else
        open(unit=outunit,file=outfile,position='append',form='formatted')
        write(outunit,103) np(1), M2tree*np(1)/sum_M2tree, M2loop0_in/M2tree, '', '', trim(stabstatus), &
          & abscorr_thr, trigeff_local, (rONE*np(2))/np(1), (rONE*np(3))/np(1), &
          & (rONE*np(4))/np(1), (rONE*np(5))/np(1), (rONE*np(6))/np(1)
        close(outunit)
      end if
    end if

    if (write_stab) then
      call write_histogram(processname, hist, np(2:6))
    end if

  end if

   90 format(7A14)
   91 format(2I14,5ES14.1E2)
  101 format(A10,12A14)
  102 format(I10,ES14.1E2,2ES14.3E2,ES14.1E2, A14, 7ES14.3E2)
  103 format(I10,ES14.1E2,ES14.3E2, 3A14, 7ES14.3E2)

end subroutine stability_trigger



subroutine update_stability_histogram(processname, hist, rel_deviation, qp_eval, killed)
  use kind_types, only: dp
  use ol_parameters_decl_dp, only: stability_log
  implicit none
  character(*), intent(in) :: processname
  integer, intent(inout) :: hist(:)
  real(dp), intent(in) :: rel_deviation
  integer, intent(in) :: qp_eval, killed

  if (stability_log <= 0) return

  if (rel_deviation > 100)                hist( 1) = hist( 1) + 1
  if (rel_deviation > 10)                 hist( 2) = hist( 2) + 1
  if (rel_deviation > 1)                  hist( 3) = hist( 3) + 1
  if (rel_deviation > 0.1)                hist( 4) = hist( 4) + 1
  if (rel_deviation > 0.01)               hist( 5) = hist( 5) + 1
  if (rel_deviation > 0.001)              hist( 6) = hist( 6) + 1
  if (rel_deviation > 0.0001)             hist( 7) = hist( 7) + 1
  if (rel_deviation > 0.00001)            hist( 8) = hist( 8) + 1
  if (rel_deviation > 0.000001)           hist( 9) = hist( 9) + 1
  if (rel_deviation > 0.0000001)          hist(10) = hist(10) + 1
  if (rel_deviation > 0.00000001)         hist(11) = hist(11) + 1
  if (rel_deviation > 0.000000001)        hist(12) = hist(12) + 1
  if (rel_deviation > 0.0000000001)       hist(13) = hist(13) + 1
  if (rel_deviation > 0.00000000001)      hist(14) = hist(14) + 1
  if (rel_deviation > 0.000000000001)     hist(15) = hist(15) + 1
  if (rel_deviation > 0.0000000000001)    hist(16) = hist(16) + 1
  if (rel_deviation > 0.00000000000001)   hist(17) = hist(17) + 1
  if (rel_deviation > 0.000000000000001)  hist(18) = hist(18) + 1
  if (rel_deviation > 0.0000000000000001) hist(19) = hist(19) + 1
  hist(20) = hist(20) + 1

  if (check_stability_write(hist(20))) then
    call write_histogram(processname, hist, [qp_eval, killed])
  end if

end subroutine update_stability_histogram



subroutine finish_histograms(processname, hist, hist_qp, np, qp_eval, killed)
  use ol_parameters_decl_dp, only: stability_log
  use ol_loop_parameters_decl_dp, only: stability_mode
  implicit none
  character(*), intent(in) :: processname
  integer, intent(in) :: hist(:)
  integer, intent(in) :: hist_qp(:)
  integer :: np(:)
  integer :: qp_eval, killed
  if (stability_log > 0) then
    if (stability_mode == 12 .or. stability_mode == 13 .or. stability_mode == 14) then
      call write_histogram(processname, hist, [qp_eval, killed])
    end if
    if (stability_mode == 14 .or. stability_mode == 23 .or. stability_mode == 32) then
      call write_histogram(trim(processname) // "_qp", hist_qp, [qp_eval, killed])
    end if
    if (stability_mode == 21 .or. stability_mode == 22 .or. stability_mode == 23) then
      if (np(1) == 0) then
        ! loop induced
        call write_histogram(processname, hist, [qp_eval, killed])
      else
        call write_histogram(processname, hist, np)
      end if
    end if
  end if
end subroutine finish_histograms



subroutine vamp2_dp(vamp2, P_scatt, M2L0, M2L1, IRL1, M2L2, IRL2, redlib, mode)
  use kind_types, only: dp
  use ol_init, only: set_parameter, parameters_flush
  use ol_parameters_decl_dp, only: a_switch
  implicit none
  real(dp), intent(in)  :: P_scatt(:,:)
  real(dp), intent(out) :: M2L0, M2L1(0:2), IRL1(0:2), M2L2(0:4), IRL2(0:4)
  integer, intent(in), optional :: redlib, mode
  integer :: redlib_bak
  interface
    subroutine vamp2(P_scatt, M2L0, M2L1, IRL1, M2L2, IRL2, mode)
      use kind_types, only: dp
      implicit none
      real(dp), intent(in)  :: P_scatt(:,:)
      real(dp), intent(out) :: M2L0, M2L1(0:2), IRL1(0:2), M2L2(0:4), IRL2(0:4)
      integer, intent(in), optional :: mode
    end subroutine vamp2
  end interface
  redlib_bak = -1
  if (present(redlib)) then
    if (redlib /= a_switch .and. redlib >= 0) then
      redlib_bak = a_switch
      call set_parameter("redlib1", redlib)
      call parameters_flush()
    end if
  end if
  call vamp2(P_scatt, M2L0, M2L1, IRL1, M2L2, IRL2, mode=mode)
  if (redlib_bak >= 0) then
    call set_parameter("redlib1", redlib_bak)
    call parameters_flush()
  end if
end subroutine vamp2_dp



function vamp2_dp_scaled(vamp2, P_scatt, M2L0, M2L1, IRL1, M2L2, IRL2, redlib)
  use kind_types, only: dp
  use ol_parameters_decl_dp, only: rONE, rescalefactor, scaling_mode
  use ol_loop_parameters_decl_dp, only: deviation_mode, polecheck_is
  use ol_init, only: set_parameter, parameters_flush
  use ol_generic, only: relative_deviation
  implicit none
  real(dp), intent(in)  :: P_scatt(:,:)
  real(dp), intent(out) :: M2L0, M2L1(0:2), IRL1(0:2), M2L2(0:4), IRL2(0:4)
  integer, intent(in), optional :: redlib
  real(dp) :: vamp2_dp_scaled
  integer :: redlib_dp, mode2
  real(dp) :: M2L0_scaled, M2L1_scaled(0:2), IRL1_scaled(0:2), M2L2_scaled(0:4), IRL2_scaled(0:4)
  interface
    subroutine vamp2(P_scatt, M2L0, M2L1, IRL1, M2L2, IRL2, mode)
      use kind_types, only: dp
      implicit none
      real(dp), intent(in)  :: P_scatt(:,:)
      real(dp), intent(out) :: M2L0, M2L1(0:2), IRL1(0:2), M2L2(0:4), IRL2(0:4)
      integer, intent(in), optional :: mode
    end subroutine vamp2
  end interface
  if (present(redlib)) then
    redlib_dp = redlib
  else
    redlib_dp = -1
  end if
  if (scaling_mode == 3 .or. polecheck_is == 1) then
    mode2 = 1
  else
    mode2 = 2
  end if
  call vamp2_dp(vamp2, P_scatt, M2L0, M2L1, IRL1, M2L2, IRL2, &
              & redlib=redlib_dp, mode=1)
  call set_parameter("scalefactor", rescalefactor)
  call parameters_flush()
  call vamp2_dp(vamp2, P_scatt, M2L0_scaled, M2L1_scaled, IRL1_scaled, M2L2_scaled, IRL2_scaled, &
              & redlib=redlib_dp, mode=mode2)
  call set_parameter("scalefactor", rONE)
  call parameters_flush()
  if (M2L0 == 0) then
    ! loop induced
    ! relative deviation, deviation_mode has no effect
    vamp2_dp_scaled = relative_deviation(M2L2(0), M2L2_scaled(0))
    last_vme2 = M2L2(0)
    last_vme2_scaled = M2L2_scaled(0)
    if (abs(M2L2_scaled(0)) < abs(M2L2(0))) then
      ! return the result with the smaller loop^2
      M2L0 = M2L0_scaled
      M2L1 = M2L1_scaled
      IRL1 = IRL1_scaled
      M2L2 = M2L2_scaled
      IRL2 = IRL2_scaled
    end if
  else
    ! relative deviation
    if (deviation_mode == 1) then
      ! k-factor based
      vamp2_dp_scaled = abs(M2L1(0) - M2L1_scaled(0)) / M2L0
    else
      vamp2_dp_scaled = relative_deviation(M2L1(0), M2L1_scaled(0))
    end if
    last_vme2 = M2L1(0)
    last_vme2_scaled = M2L1_scaled(0)
    if (abs(M2L1_scaled(0)) < abs(M2L1(0))) then
      ! return the result with the smaller tree-loop interference
      M2L0 = M2L0_scaled
      M2L1 = M2L1_scaled
      IRL1 = IRL1_scaled
      M2L2 = M2L2_scaled
      IRL2 = IRL2_scaled
    end if
  end if
end function vamp2_dp_scaled





subroutine vamp2_qp(vamp2, P_scatt, M2L0, M2L1, IRL1, M2L2, IRL2, redlib, mode)
  use kind_types, only: dp, qp
  use ol_init, only: set_parameter, parameters_flush
  use ol_parameters_decl_dp, only: a_switch
  implicit none
  real(dp), intent(in)  :: P_scatt(:,:)
  real(dp), intent(out) :: M2L0, M2L1(0:2), IRL1(0:2), M2L2(0:4), IRL2(0:4)
  integer, intent(in), optional :: redlib, mode
  integer :: redlib_bak
  real(qp) :: M2L0_qp, M2L1_qp(0:2), IRL1_qp(0:2), M2L2_qp(0:4), IRL2_qp(0:4)
  interface
    subroutine vamp2(P_scatt, M2L0, M2L1, IRL1, M2L2, IRL2, mode)
      use kind_types, only: dp, qp
      implicit none
      real(dp), intent(in)  :: P_scatt(:,:)
      real(qp), intent(out) :: M2L0, M2L1(0:2), IRL1(0:2), M2L2(0:4), IRL2(0:4)
      integer, intent(in), optional :: mode
    end subroutine vamp2
  end interface
  redlib_bak = -1
  if (present(redlib)) then
    if (redlib /= a_switch .and. redlib >= 0) then
      redlib_bak = a_switch
      call set_parameter("redlib1", redlib)
      call parameters_flush()
    end if
  end if
  call vamp2(P_scatt, M2L0_qp, M2L1_qp, IRL1_qp, M2L2_qp, IRL2_qp, mode=mode)
  M2L0 = M2L0_qp
  M2L1 = M2L1_qp
  IRL1 = IRL1_qp
  M2L2 = M2L2_qp
  IRL2 = IRL2_qp
  if (redlib_bak >= 0) then
    call set_parameter("redlib1", redlib_bak)
    call parameters_flush()
  end if
end subroutine vamp2_qp



function vamp2_qp_scaled(vamp2, P_scatt, M2L0, M2L1, IRL1, M2L2, IRL2, redlib)
  use kind_types, only: dp, qp
  use ol_parameters_decl_dp, only: rONE, rescalefactor, scaling_mode
  use ol_loop_parameters_decl_dp, only: deviation_mode, polecheck_is
  use ol_init, only: set_parameter, parameters_flush
  use ol_generic, only: relative_deviation
  implicit none
  real(dp), intent(in)  :: P_scatt(:,:)
  real(dp), intent(out) :: M2L0, M2L1(0:2), IRL1(0:2), M2L2(0:4), IRL2(0:4)
  integer, intent(in), optional :: redlib
  integer :: redlib_qp, mode2
  real(dp) :: vamp2_qp_scaled
  real(dp) :: M2L0_scaled, M2L1_scaled(0:2), IRL1_scaled(0:2), M2L2_scaled(0:4), IRL2_scaled(0:4)
  interface
    subroutine vamp2(P_scatt, M2L0, M2L1, IRL1, M2L2, IRL2, mode)
      use kind_types, only: dp, qp
      implicit none
      real(dp), intent(in)  :: P_scatt(:,:)
      real(qp), intent(out) :: M2L0, M2L1(0:2), IRL1(0:2), M2L2(0:4), IRL2(0:4)
      integer, intent(in), optional :: mode
    end subroutine vamp2
  end interface
  if (present(redlib)) then
    redlib_qp = redlib
  else
    redlib_qp = -1
  end if
  if (scaling_mode == 3 .or. polecheck_is == 1) then
    mode2 = 1
  else
    mode2 = 2
  end if
  call vamp2_qp(vamp2, P_scatt, M2L0, M2L1, IRL1, M2L2, IRL2, &
              & redlib=redlib_qp, mode=1)
  call set_parameter("scalefactor", rescalefactor)
  call parameters_flush()
  call vamp2_qp(vamp2, P_scatt, M2L0_scaled, M2L1_scaled, IRL1_scaled, M2L2_scaled, IRL2_scaled, &
              & redlib=redlib_qp, mode=mode2)
  call set_parameter("scalefactor", rONE)
  call parameters_flush()
  if (M2L0 == 0) then
    ! loop induced
    ! relative deviation, deviation_mode has no effect
    vamp2_qp_scaled = relative_deviation(M2L2(0), M2L2_scaled(0))
    last_vme2 = M2L2(0)
    last_vme2_scaled = M2L2_scaled(0)
    if (abs(M2L2_scaled(0)) < abs(M2L2(0))) then
      ! return the result with the smaller loop^2
      M2L0 = M2L0_scaled
      M2L1 = M2L1_scaled
      IRL1 = IRL1_scaled
      M2L2 = M2L2_scaled
      IRL2 = IRL2_scaled
    end if
  else
    ! relative deviation
    if (deviation_mode == 1) then
      ! k-factor based
      vamp2_qp_scaled = abs(M2L1(0) - M2L1_scaled(0)) / M2L0
    else
      vamp2_qp_scaled = relative_deviation(M2L1(0), M2L1_scaled(0))
    end if
    last_vme2 = M2L1(0)
    last_vme2_scaled = M2L1_scaled(0)
    if (abs(M2L1_scaled(0)) < abs(M2L1(0))) then
      ! return the result with the smaller tree-loop interference
      M2L0 = M2L0_scaled
      M2L1 = M2L1_scaled
      IRL1 = IRL1_scaled
      M2L2 = M2L2_scaled
      IRL2 = IRL2_scaled
    end if
  end if
end function vamp2_qp_scaled

! #ifdef 1




subroutine vamp2generic(vamp2dp, vamp2qp, processname, P_scatt, M2L0, M2L1, IRL1, M2L2, IRL2, &
                      & abs_kfactor_threshold, trigeff_local, sum_M2tree, &
                      & npoints, qp_eval, killed, stability_histogram, stability_histogram_qp, &
                      & extperm, me_caches)
  use kind_types, only: dp
  use ol_data_types_dp, only: me_cache
  use ol_parameters_decl_dp, only: verbose, current_processname, a_switch, &
    & a_switch_rescue, redlib_qp, write_psp, use_me_cache, parameters_changed
  use ol_loop_parameters_decl_dp, only: ratcorr_bad, ratcorr_bad_L2, stability_mode, abscorr_unst
  use ol_generic, only: relative_deviation, factorial, perm_pos, to_string
  implicit none
  character(*), intent(in) :: processname
  real(dp), intent(in)  :: P_scatt(:,:)
  real(dp), intent(out) :: M2L0, M2L1(0:2), IRL1(0:2), M2L2(0:4), IRL2(0:4)
  real(dp), intent(inout) :: abs_kfactor_threshold, trigeff_local, sum_M2tree
  integer, intent(inout) :: npoints(8), qp_eval, killed
  integer, intent(inout) :: stability_histogram(20), stability_histogram_qp(20)
  integer, intent(in) :: extperm(:)
  type(me_cache), allocatable, target, intent(inout) :: me_caches(:)
  real(dp) :: M2L1_rescue(0:2), M2L2_rescue(0:4), abs_kfactor, abs_kfactor_rescue
  type(me_cache), pointer :: cache



  interface
    subroutine vamp2dp(P_scatt, M2L0, M2L1, IRL1, M2L2, IRL2, mode)
      use kind_types, only: dp
      implicit none
      real(dp), intent(in)  :: P_scatt(:,:)
      real(dp), intent(out) :: M2L0, M2L1(0:2), IRL1(0:2), M2L2(0:4), IRL2(0:4)
      integer, intent(in), optional :: mode
    end subroutine vamp2dp
  end interface

  interface
    subroutine vamp2qp(P_scatt, M2L0, M2L1, IRL1, M2L2, IRL2, mode)
      use kind_types, only: dp, qp
      implicit none
      real(dp), intent(in)  :: P_scatt(:,:)
      real(qp), intent(out) :: M2L0, M2L1(0:2), IRL1(0:2), M2L2(0:4), IRL2(0:4)
      integer, intent(in), optional :: mode
    end subroutine vamp2qp
  end interface


  current_processname = processname
  last_relative_deviation = -1
  last_vme2 = -1
  last_vme2_scaled = -1

  if (write_psp == 1) then
    call write_point(processname, psp=P_scatt)
  end if

  if (use_me_cache > 0) then
    ! (123+441=564) byte/me_cache (unallocated+allocated=total)
    ! 49 for arr(:); 74 for arr(:,:); 123 for psp(:,:), me(:)
    if (.not. allocated(me_caches)) allocate(me_caches(factorial(size(extperm))))
    cache => me_caches(perm_pos(extperm))
    if (.not. allocated(cache%psp)) then
      allocate(cache%psp(0:3,size(extperm)))
      cache%psp = -1
      allocate(cache%me(18))
    end if
    if (all(cache%psp == P_scatt) .and. parameters_changed == 0) then
      if (verbose >= 2) print *, trim(current_processname) // trim(to_string(extperm)) // ' taken from the cache'
      M2L0 = cache%me(1)
      M2L1 = cache%me(2:4)
      IRL1 = cache%me(5:7)
      M2L2 = cache%me(8:12)
      IRL2 = cache%me(13:17)
      last_relative_deviation = cache%me(18)
      if (write_psp == 1) then
        call write_point(processname, me=[M2L0, M2L1(0), M2L1(1), M2L1(2), M2L2(0)])
      end if
      return
    end if
  end if

  if (stability_mode == 11) then
    ! double precision with a single library
    call vamp2_dp(vamp2dp, P_scatt, M2L0, M2L1, IRL1, M2L2, IRL2)


  else if (stability_mode == 12) then
    ! double precision + scaling with a single library
    last_relative_deviation = vamp2_dp_scaled(vamp2dp, P_scatt, M2L0, M2L1, IRL1, M2L2, IRL2)
    if (last_relative_deviation > ratcorr_bad) then
      ! kill point
      killed = killed + 1
      M2L1(0) = 0
    end if
    call update_stability_histogram(processname, stability_histogram, last_relative_deviation, qp_eval, killed)



  else if (stability_mode == 13) then
    ! double precision + scaling with a single library
    ! + quad precision with (possibly) a different library
    last_relative_deviation = vamp2_dp_scaled(vamp2dp, P_scatt, M2L0, M2L1, IRL1, M2L2, IRL2)
    if (last_relative_deviation > abscorr_unst) then
      qp_eval = qp_eval + 1
      call vamp2_qp(vamp2qp, P_scatt, M2L0, M2L1, IRL1, M2L2, IRL2, redlib_qp)
    end if
    call update_stability_histogram(processname, stability_histogram, last_relative_deviation, qp_eval, killed)


  else if (stability_mode == 14) then
    ! double precision + scaling with a single library
    ! + quad precision with (possibly) a different library + scaling
    last_relative_deviation = vamp2_dp_scaled(vamp2dp, P_scatt, M2L0, M2L1, IRL1, M2L2, IRL2)
    call update_stability_histogram(processname, stability_histogram, last_relative_deviation, qp_eval, killed)
    if (last_relative_deviation > abscorr_unst) then
      qp_eval = qp_eval + 1
      last_relative_deviation = vamp2_qp_scaled(vamp2qp, P_scatt, M2L0, M2L1, IRL1, M2L2, IRL2, redlib_qp)
      if (last_relative_deviation > ratcorr_bad) then
        ! kill point
        killed = killed + 1
        M2L1(0) = 0
      end if
    end if
    call update_stability_histogram(trim(processname) // "_qp", stability_histogram_qp, &
      & last_relative_deviation, qp_eval, killed)


  else if (stability_mode == 15) then
    ! double precision + scaling with a single library + quad precision
    ! log dp and qp results, return qp
    last_relative_deviation = vamp2_dp_scaled(vamp2dp, P_scatt, M2L0, M2L1, IRL1, M2L2, IRL2)
    call last_scaling_result(M2L2_rescue(1), M2L2_rescue(2), last_relative_deviation)
    call vamp2_qp(vamp2qp, P_scatt, M2L0, M2L1, IRL1, M2L2, IRL2, redlib_qp)
    M2L2_rescue(0) = M2L0
    if (M2L1(0) == 0) then
      M2L2_rescue(3) = M2L2(0)
    else
      M2L2_rescue(3) = M2L1(0)
    end if
    ! data: tree, loop, loop_scaled, qp
    call write_result(processname, M2L2_rescue(0:3))


  else if (stability_mode == 16) then
    ! double precision + scaling with a single library + quad precision + scaling
    ! log dp and qp results, return qp
    last_relative_deviation = vamp2_dp_scaled(vamp2dp, P_scatt, M2L0, M2L1, IRL1, M2L2, IRL2)
    call last_scaling_result(M2L2_rescue(1), M2L2_rescue(2), last_relative_deviation)
    last_relative_deviation = vamp2_qp_scaled(vamp2qp, P_scatt, M2L0, M2L1, IRL1, M2L2, IRL2, redlib_qp)
    M2L2_rescue(0) = M2L0
    call last_scaling_result(M2L2_rescue(3), M2L2_rescue(4), last_relative_deviation)
    ! data: tree, loop, loop_scaled, qp, qp_scaled
    call write_result(processname, M2L2_rescue)
! #ifndef 1



  else if (stability_mode >= 20 .and. stability_mode < 30) then
    if (a_switch == a_switch_rescue) then
      print *, '[OpenLoops] ERROR: stability modes 2x require different redlib1 and redlib2'
      stop
    end if
    ! reevaluation with a second library if abs(k-factor) is in
    ! the largest 'trigeff_targ' fraction of the distribution
    call vamp2_dp(vamp2dp, P_scatt, M2L0, M2L1, IRL1, M2L2, IRL2)
    if (M2L0 == 0) then
      ! loop induced: always reevaluate
      call vamp2_dp(vamp2dp, P_scatt, M2L0, M2L1_rescue, IRL1, M2L2_rescue, IRL2, redlib = a_switch_rescue)
      last_relative_deviation = relative_deviation(M2L2(0), M2L2_rescue(0))
      if (last_relative_deviation > ratcorr_bad_L2) then
        ! kill point
        killed = killed + 1
        M2L2(0) = 0
      end if
      call update_stability_histogram(processname, stability_histogram, last_relative_deviation, qp_eval, killed)
    else
      ! k-factor sanity check
      abs_kfactor = abs(M2L1(0)/M2L0)
      if (abs_kfactor > abs_kfactor_threshold) then
        ! reevaluate the matrix element with a different reduction library
        call vamp2_dp(vamp2dp, P_scatt, M2L0, M2L1_rescue, IRL1, M2L2, IRL2, redlib = a_switch_rescue)
        abs_kfactor_rescue = abs(M2L1_rescue(0)/M2L0)
      else
        abs_kfactor_rescue = abs_kfactor
        M2L1_rescue(0) = M2L1(0)
      end if
      call stability_trigger(processname, npoints, stability_histogram, &
        & abs_kfactor_threshold, trigeff_local, abs_kfactor, abs_kfactor_rescue, &
        & M2L1(0), M2L1_rescue(0), M2L0, sum_M2tree, P_scatt)
    end if


    if ((M2L0 /= 0 .and. M2L1(0) == 0) .or. (M2L0 == 0 .and. M2L2(0) == 0)) then
      ! if the point was killed and qp rescue is active, reevaluate it
      if (stability_mode == 22) then
        ! quad precision rescue
        qp_eval = qp_eval + 1
        call vamp2_qp(vamp2qp, P_scatt, M2L0, M2L1, IRL1, M2L2, IRL2, redlib = redlib_qp)
        last_relative_deviation = 0
        call update_stability_histogram(trim(processname) // "_qp", stability_histogram_qp, &
          & last_relative_deviation, qp_eval, killed)
      else if (stability_mode == 23) then
        ! quad precision rescue + scaling
        qp_eval = qp_eval + 1
        last_relative_deviation = vamp2_qp_scaled(vamp2qp, P_scatt, M2L0, M2L1, IRL1, M2L2, IRL2, redlib = redlib_qp)
        if (last_relative_deviation > ratcorr_bad) then
          ! kill point
          killed = killed + 1
          M2L1(0) = 0
        end if
        call update_stability_histogram(trim(processname) // "_qp", stability_histogram_qp, &
          & last_relative_deviation, qp_eval, killed)
      end if
    end if

  else if (stability_mode == 31) then
    ! quad precision with a single library
    call vamp2_qp(vamp2qp, P_scatt, M2L0, M2L1, IRL1, M2L2, IRL2, redlib = redlib_qp)


  else if (stability_mode == 32) then
    ! quad precision + scaling with a single library
    qp_eval = qp_eval + 1
    last_relative_deviation = vamp2_qp_scaled(vamp2qp, P_scatt, M2L0, M2L1, IRL1, M2L2, IRL2, redlib = redlib_qp)
    if (last_relative_deviation > ratcorr_bad) then
      ! kill point
      killed = killed + 1
      M2L1(0) = 0
    end if
    call update_stability_histogram(processname // "_qp", stability_histogram_qp, &
      & last_relative_deviation, qp_eval, killed)
! #ifndef 1


  else
    print *, "ERROR: unknown stability mode:", stability_mode



    stop

  end if

  if (write_psp == 1) then
    call write_point(processname, me=[M2L0, M2L1(0), M2L1(1), M2L1(2), M2L2(0)])
  end if

  ! fill matrix element cache
  if (use_me_cache > 0) then
    cache%psp = P_scatt
    cache%me(1)     = M2L0
    cache%me(2:4)   = M2L1
    cache%me(5:7)   = IRL1
    cache%me(8:12)  = M2L2
    cache%me(13:17) = IRL2
    cache%me(18)    = last_relative_deviation
  end if

end subroutine vamp2generic

end module ol_stability

