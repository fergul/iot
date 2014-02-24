interface KNoTCrypt{

	/* Checks the sequence number and returns 1 if in sequence, 0 otherwise */
	command int valid_seqno(ChanState *state, PDataPayload *pdp);

	/* Sends PDataPayload on a KNoT channel specified in the state */
	command void send_on_chan(ChanState *state, PDataPayload *pdp);

	/* Sends a PDataPayload as a broadcast transmission */
	command void knot_broadcast(ChanState *state);

	command void query(ChanState* state, uint8_t type);

	command void query_handler(ChanState *state, PDataPayload *pdp, uint8_t src);

	command void qack_handler(ChanState *state, PDataPayload *pdp, uint8_t src);

	command void connect(ChanState *new_state, uint8_t addr, int rate);

	command void connect_handler(ChanState *state, PDataPayload *pdp, uint8_t src);

	command uint8_t controller_cack_handler(ChanState *state, PDataPayload *pdp);

	command uint8_t sensor_cack_handler(ChanState *state, PDataPayload *pdp);

	command void send_value(ChanState *state, uint8_t *data, uint8_t len);

	command void response_handler(ChanState *state, PDataPayload *pdp);
	
	command void send_rack(ChanState *state);
	command void rack_handler(ChanState *state, PDataPayload *pdp);

	/* Sends a ping packet to the channel in state */
	command void ping(ChanState *state);

	/* Handles the reception of a PING packet, replies with a PACK */
	command void ping_handler(ChanState *state, PDataPayload *pdp);

	/* Handles the reception of a PACK packet */
	command void pack_handler(ChanState *state, PDataPayload *pdp);

	/* Closes the channel specified and sends out a DISCONNECT packet */
	command void close_graceful(ChanState *state);

	/* Handles the reception of a DISCONNECT packet */
	command void disconnect_handler(ChanState *state, PDataPayload *pdp);

	command void init_symmetric(ChanState *state, uint8_t *key, uint8_t key_size);
    command void receiveDecrypt(ChanState *state, SSecPacket *sp, uint8_t len, uint8_t *valid);
	
	command void init_assymetric(uint16_t *priv_key, uint16_t *pub_key_x,
                                 uint16_t *pub_key_y, uint8_t key_size);

	event message_t* receive(uint8_t src, message_t *msg, void *payload, uint8_t len);
}