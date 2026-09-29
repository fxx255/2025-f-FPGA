run 2700 us
puts "VERIFY is_fm=[get_value /tb_fm_demod_fft/dut/is_fm]"
puts "VERIFY dev_gain=[get_value /tb_fm_demod_fft/dut/dev_gain]"
puts "VERIFY lo_freq_word=[get_value -radix hex /tb_fm_demod_fft/dut/lo_freq_word]"
for {set i 0} {$i < 40} {incr i} { run 5 us; puts "SAMP [get_value -radix dec /tb_fm_demod_fft/dac_signed]" }
quit
