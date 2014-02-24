#include <string.h>
#include <stdlib.h>
#include "Timer.h"
#include "ChannelTable.h"
#include "ChannelState.h"
#include "KNoTProtocol.h"
#include "KNoT.h"
#if DEBUG
#include "printf.h"
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

module ControllerC @safe()
{
  uses {
    interface Boot;
    interface SplitControl as SerialControl;
    interface AMSend as SerialSend;
    interface Receive as SerialReceive;
    interface Timer<TMilli> as CleanerTimer;
    interface LEDBlink;
    interface ChannelTable;
    interface ChannelState;
    interface KNoTCrypt as KNoT;
  }
}
implementation
{
	ChanState home_chan;
	bool serialSendBusy = FALSE;
	uint8_t testKey[] = {0x05,0x15,0x25,0x35,0x45,0x55,0x65,0x75,0x85,0x95};
	uint8_t testKey_size = 10;

		/* Checks the timer for a channel's state, retransmitting when necessary */
	void check_timer(ChanState *state) {
    decrement_ticks(state);
    if (ticks_left(state)) return;
    if (attempts_left(state)) {
    	if (in_waiting_state(state)) 
        call KNoT.send_on_chan(state, &(state->packet));
      else 
        call KNoT.ping(state); /* PING A LING LONG */
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
      
	/*------------------------------------------------- */
	
	event void Boot.booted() {
		PRINTF("\n*********************\n****** BOOTED *******\n*********************\n");
    PRINTFFLUSH();
    call LEDBlink.report_problem();
    call ChannelTable.init_table();
    call ChannelState.init_state(&home_chan, 0);
    call CleanerTimer.startPeriodic(TICK_RATE);
    call KNoT.init_symmetric(&home_chan, testKey, testKey_size);
    }
    
 	event void SerialControl.startDone(error_t error) {}

  event void SerialControl.stopDone(error_t error) {}
   
/*-----------Received packet event, main state event ------------------------------- */
  event message_t* KNoT.receive(uint8_t src, message_t* msg, void* payload, uint8_t len) {
    uint8_t valid = 0;
  	ChanState *state;
  	uint8_t cmd;
  	Packet *p = (Packet *) payload;
    SSecPacket *sp = NULL;
    PDataPayload *pdp = NULL;
    ChanHeader *ch = NULL;
	/* Gets data from the connection */
	  PRINTF("SEC>> Received %s packet\n", is_symmetric(p->flags)?"Symmetric":
    			                               is_asymmetric(p->flags)?"Asymmetric":"Plain");

  	if (is_symmetric(p->flags)) {
      PRINTF("SEC>> IV: %d\n", sp->flags & (0xff >> 2));PRINTFFLUSH();
  		sp = (SSecPacket *) p;
      if (sp->ch.dst_chan_num) { /* Get CC for channel */ 
        state = call ChannelTable.get_channel_state(sp->ch.dst_chan_num);
        if (!state){ /* If bogus request kill bogie */
          PRINTF("Channel %d doesn't exist\n", ch->dst_chan_num);
          state = &home_chan;
          state->remote_chan_num = ch->src_chan_num;
          state->remote_addr = src;
          state->seqno = pdp->dp.hdr.seqno;
          call KNoT.close_graceful(state);
          return msg;
        }
      }
      else state = &home_chan;

  		call KNoT.receiveDecrypt(state, sp, len, &valid);
      if (!valid) return msg; /* Return if decryption failed */

  		pdp = (PDataPayload *) (&sp->ch); /* Offsetting to start of pdp */
  	} 
    else if (is_asymmetric(p->flags)) {
      if (!isAsymActive()) return msg; /* Don't waste time/energy */
      switch(p->flags){
        case(ASYM_QUERY): PRINTF("ASymQuery - create new channel\n");break;
        case(ASYM_RESPONSE): PRINTF("ASymResponse\n");break;
        case(ASYM_KEY_TX): PRINTF("ASymKeyTransmit\n");break;
        default: PRINTF("Unknown type\n");
      }
    }
    else pdp = (PDataPayload *) &(p->ch);

    ch = &(pdp->ch);
  	cmd = pdp->dp.hdr.cmd;
  	PRINTF("CON>> Received packet from Thing: %d\n", src);
  	PRINTF("CON>> Received a %s command\n", cmdnames[cmd]);
  	PRINTF("CON>> Message for channel %d\n", ch->dst_chan_num);
  	PRINTFFLUSH();

  	switch(cmd) { /* Drop packets for cmds we don't accept */
      case(QUERY): PRINTF("NOT FOR US\n");PRINTFFLUSH(); return msg;
      case(CONNECT): return msg;
      case(QACK): call KNoT.qack_handler(&home_chan, pdp, src); return msg;
      case(DACK): return msg;
  	}
    /* Grab state for requested channel */
  	state = call ChannelTable.get_channel_state(ch->dst_chan_num);
  	if (!state){ /* Attempt to kill connection if no state held */
  		PRINTF("Channel %d doesn't exist\n", ch->dst_chan_num);
  		state = &home_chan;
  		state->remote_chan_num = ch->src_chan_num;
  		state->remote_addr = src;
  		state->seqno = pdp->dp.hdr.seqno;
  		call KNoT.close_graceful(state);
  		return msg;
  	} else if (!call KNoT.valid_seqno(state, pdp)) {
  		PRINTF("Old packet\n");
  		return msg;
  	}
  	switch(cmd) {
  		case(CACK): call KNoT.controller_cack_handler(state, pdp); break;
  		case(RESPONSE): call KNoT.response_handler(state, pdp); break;
  		case(RSYN): call KNoT.response_handler(state, pdp); call KNoT.send_rack(state); break;
  		// case(CMDACK):   	command_ack_handler(state,pdp);break;
  		case(PING): call KNoT.ping_handler(state, pdp); break;
  		case(PACK): call KNoT.pack_handler(state, pdp); break;
  		case(DISCONNECT): call KNoT.disconnect_handler(state, pdp); 
  	                    call ChannelTable.remove_channel(state->chan_num); break;
  		default: PRINTF("Unknown CMD type\n");
  	}
    call LEDBlink.report_received();
    return msg; /* Return packet to TinyOS */
  }

    
	event message_t *SerialReceive.receive(message_t *msg, void* payload, uint8_t len){
  	PDataPayload *pdp = (PDataPayload *)payload;
  	void * data = &(pdp->dp.data);
  	uint8_t cmd = pdp->dp.hdr.cmd;
  	call LEDBlink.report_received();
		
		PRINTF("SERIAL> Serial command received.\n");
		PRINTF("SERIAL> Packet length: %d\n", pdp->dp.dhdr.tlen);
		//PRINTF("SERIAL> Message for channel %d\n", ch->dst_chan_num);
		PRINTF("SERIAL> Command code: %d\n", pdp->dp.hdr.cmd);
		PRINTFFLUSH();

		switch (cmd) {
			case(QUERY): call KNoT.query(&home_chan, 1/*((QueryMsg*)dp)->type*/);break;
			case(CONNECT): call KNoT.connect(call ChannelTable.new_channel(), 
													             ((SerialConnect*)data)->addr, 
													             ((SerialConnect*)data)->rate);break;
		}
		call LEDBlink.report_received();
  	return msg;
    }

 	event void SerialSend.sendDone(message_t *msg, error_t error){
  	if (error == SUCCESS) call LEDBlink.report_sent();
    else call LEDBlink.report_problem();
    serialSendBusy = FALSE;
  }

   
  event void CleanerTimer.fired(){
  	cleaner();
  }

}