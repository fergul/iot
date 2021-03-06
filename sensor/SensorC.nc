#include <string.h>
#include <stdlib.h>
#include "Timer.h"
#include "ChannelTable.h"
#include "ChannelState.h"
#include "KNoTProtocol.h"
#include "KNoT.h"
#if DEBUG
#define PRINTF(...) printf(__VA_ARGS__)
#define PRINTFFLUSH(...) printfflush()
#elif SIM
#define PRINTF(...) dbg("DEBUG",__VA_ARGS__)
#define PRINTFFLUSH(...)
#else  
#define PRINTF(...)
#define PRINTFFLUSH(...)
#endif

#define HOME_CHANNEL 0

module SensorC @safe()
{
    uses {
        interface Boot;
        interface Timer<TMilli>;
        interface Timer<TMilli> as CleanerTimer;
        interface Read<uint16_t> as LightSensor;
        interface Read<uint16_t> as TempSensor;
        interface LEDBlink;
        interface ChannelTable;
        interface ChannelState;
        interface KNoT;
    }
}
implementation
{
	nx_uint16_t temp;
    nx_uint8_t light;
	ChanState home_chan;


    /* Checks the timer for a channel's state, retransmitting when necessary */
    void check_timer(ChanState *state) {
        decrement_ticks(state);
        if (ticks_left(state)) return;
        if (attempts_left(state)) {
            if (in_waiting_state(state)) {
                call KNoT.send_on_chan(state, &(state->packet));
            } else if (state->state == STATE_CONNECTED){ 
                state->state = STATE_RSYN;
                PRINTF("Set RSYN state\n");
            } else {
                call KNoT.ping(state); /* PING A LING LONG */
            }
            set_ticks(state, state->ticks * 2); /* Exponential (double) retransmission */
            decrement_attempts(state);
            PRINTF("CLN>> Attempts left %d\n", state->attempts_left);
            PRINTF("CLN>> Retrying packet...\n");
        } else {
            PRINTF("CLN>> CLOSING CHANNEL DUE TO TIMEOUT\n");
            call KNoT.close_graceful(state);
            call ChannelTable.remove_channel(state->chan_num);
        }
        
    }

    /* Run once every 20ms */
    void cleaner(){
        ChanState *state;
        int i = 1;
        for (; i < CHANNEL_NUM; i++) {
            state = call ChannelTable.get_channel_state(i);
            if (state) check_timer(state);
        }
        /*if (home_channel_state.state != STATE_IDLE) {
                check_timer(&home_channel_state);
        }*/
    }
	/*------------------------------------------------------- */

      
	/*------------------------------------------------- */
	
	event void Boot.booted() {
		PRINTF("*********************\n****** BOOTED *******\n*********************\n");
        
        call LEDBlink.report_problem();
        call ChannelTable.init_table();
        call ChannelState.init_state(&home_chan, 0);
        //call Timer.startOneShot(5000);
        call CleanerTimer.startPeriodic(TICK_RATE);
    }

    void setup_sensor(uint8_t connected){
        if (!connected) return;
        call Timer.startPeriodic(5000);

    }
   
/*-----------Received packet event, main state event ------------------------------- */
    event message_t* KNoT.receive(uint8_t src, message_t* msg, void* payload, uint8_t len) {
    	ChanState *state;
        DataPayload *dp = (DataPayload *) payload;
		/* Gets data from the connection */
	    uint8_t cmd = dp->hdr.cmd;
		PRINTF("SEN>> Received packet from Thing: %d\n", src);
		PRINTF("SEN>> Data is %d bytes long\n", dp->dhdr.tlen);
		PRINTF("SEN>> Received a %s command\n", cmdnames[cmd]);
		PRINTF("SEN>> Message for channel %d\n", dp->hdr.dst_chan_num);
        

        switch(cmd){
            case(QUERY): call KNoT.query_handler(&home_chan, dp, src); return msg;
            case(CONNECT): call KNoT.connect_handler(call ChannelTable.new_channel(), dp, src); return msg;
            case(DACK): return msg;
        }

        /* Grab state for requested channel */
        state = call ChannelTable.get_channel_state(dp->hdr.dst_chan_num);
        /* Always allow disconnections to prevent crazies */
        if (!state){ /* Attempt to kill connection if no state held */
            PRINTF("Channel %d doesn't exist\n", dp->hdr.dst_chan_num);
            state = &home_chan;
            state->remote_chan_num = dp->hdr.src_chan_num;
            state->remote_addr = src;
            state->seqno = dp->hdr.seqno;
            call KNoT.close_graceful(state);
            return msg;
        } else if (!call KNoT.valid_seqno(state, dp)) {
            PRINTF("Old packet\n");
            return msg;
        }
        /* PUT IN QUERY CHECK FOR TYPE */
        switch(cmd){
            case(CACK): setup_sensor(call KNoT.sensor_cack_handler(state, dp)); break;
            case(PING): call KNoT.ping_handler(state, dp); break;
            case(PACK): call KNoT.pack_handler(state, dp); break;
            case(RACK): call KNoT.rack_handler(state, dp); break;
            case(DISCONNECT): call KNoT.disconnect_handler(state, dp); call Timer.stop();break;
            default: PRINTF("Unknown CMD type\n");
        }
        PRINTF("FINISHED.\n");
        call LEDBlink.report_received();
        PRINTF("----------\n");
        return msg; /* Return packet to TinyOS */
    }

    event void Timer.fired(){
        call TempSensor.read();
    }

    

    /*-----------Sensor Events------------------------------- */
    event void LightSensor.readDone(error_t result, uint16_t data) {
        if (result != SUCCESS){
            data = 0xffff;
            call LEDBlink.report_problem();
        }
        light = data;
    }
    event void TempSensor.readDone(error_t result, uint16_t data) {
        uint8_t t;
        if (result != SUCCESS){
            data = 0xffff;
            call LEDBlink.report_problem();
        }
        PRINTF("Data %d\n", data);
        temp = (float)-39.6 + (data * (float)0.01);
        t = temp;
        PRINTF("Temp: %d.%d\n", temp, temp>>2);
        PRINTF("Temp: %d\n", t);
        call KNoT.send_value(call ChannelTable.get_channel_state(1), &t, 1);
    }

    event void CleanerTimer.fired(){
        cleaner();
    }

}